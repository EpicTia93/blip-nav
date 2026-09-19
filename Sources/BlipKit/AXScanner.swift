import AppKit
import ApplicationServices
import BlipCore
import CoreGraphics
import Foundation

public struct AXScanOptions: Sendable {
    /// Ceiling on how long a single AX call may block. Without this one unresponsive
    /// app (a beachballing Electron window is the usual culprit) stalls the whole scan,
    /// because AX calls are synchronous mach IPC with no default deadline worth having.
    public var messagingTimeout: Float = 0.25
    /// Web content nests far deeper than native UI: a button inside a card inside a
    /// list inside a chat transcript is routinely 40+ levels below the app element.
    /// A limit of 25 silently cut off exactly the controls people most want to click.
    public var maxDepth = 60
    public var maxElementsPerApp = 6000
    /// Wall-clock budget per app, enforced between AX calls.
    public var perAppDeadline: TimeInterval = 0.35
    /// Controls narrower or shorter than this are separators and decorations.
    public var minimumTargetSize: CGFloat = 5
    /// Include the frontmost app's menu bar (File, Edit, View...).
    public var includeMenuBar = true
    /// Tight budget for apps with no windows, which are only asked one question:
    /// "do you own a menu bar extra?". A handful of those are unresponsive helper
    /// processes, and they must not be allowed to hold up the whole scan.
    public var extrasOnlyTimeout: Float = 0.08
    public var extrasOnlyDeadline: TimeInterval = 0.1

    public init() {}
}

public struct AXScanOutcome: Sendable {
    public var targets: [Target]
    /// Per-app wall time, for `blip-probe` and for finding the app that is slowing a
    /// scan down.
    public var timings: [String: TimeInterval]
    public var truncatedApps: [String]
}

/// Walks the Accessibility trees of every on-screen app, concurrently.
public enum AXScanner {

    /// Roles worth a hint even when the element exposes no press action.
    ///
    /// Anything outside this set still qualifies if it advertises `AXPress`, which is
    /// how custom controls and web content get picked up.
    static let actionableRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXCheckBox", "AXRadioButton", "AXLink", "AXTextField", "AXTextArea",
        "AXComboBox", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXColorWell", "AXSearchField", "AXTabButton", "AXToolbarButton",
        "AXSegmentedControl", "AXStepper", "AXSwitch",
    ]

    /// Leaf roles: never worth walking into, and walking them is expensive in
    /// text-heavy web pages where every word is its own node.
    static let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXValueIndicator"]

    public static func scan(
        windows: [ScreenWindow],
        options: AXScanOptions = AXScanOptions()
    ) async -> AXScanOutcome {
        let byPID = WindowEnumerator.groupedByPID(windows)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Every app that could own something clickable, not just those with windows.
        //
        // Agent apps (LSUIElement) live entirely in the menu bar and own no on-screen
        // window at all, so building the scan list from the window list alone silently
        // skipped every third-party status item -- including, pointedly, Blip's own.
        var pidsToScan = Set(byPID.keys)
        var namesByPID: [pid_t: String] = [:]
        for (pid, appWindows) in byPID {
            namesByPID[pid] = appWindows.first?.appName ?? "\(pid)"
        }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .accessory && !app.isTerminated {
            guard ownsStatusItemPlausibly(app) else { continue }
            let pid = app.processIdentifier
            pidsToScan.insert(pid)
            if namesByPID[pid] == nil {
                namesByPID[pid] = app.localizedName ?? "\(pid)"
            }
        }

        return await withTaskGroup(of: AppScanResult.self) { group in
            for pid in pidsToScan {
                let appWindows = byPID[pid] ?? []
                let appName = namesByPID[pid] ?? "\(pid)"
                let isFrontmost = pid == frontmostPID
                group.addTask {
                    scanApp(
                        pid: pid,
                        appName: appName,
                        windows: appWindows,
                        allWindows: windows,
                        isFrontmost: isFrontmost,
                        options: options
                    )
                }
            }

            var targets: [Target] = []
            var timings: [String: TimeInterval] = [:]
            var truncated: [String] = []
            for await result in group {
                targets.append(contentsOf: result.targets)
                timings[result.appName] = result.duration
                if result.truncated { truncated.append(result.appName) }
            }
            return AXScanOutcome(targets: targets, timings: timings, truncatedApps: truncated)
        }
    }

    /// Whether a windowless app is worth asking about a status item.
    ///
    /// Renderer and XPC helpers are `.accessory` too -- one mail client alone
    /// contributes 26 of them -- and they never own a menu bar extra while often being
    /// slow to answer AX at all. What separates them is that they live *inside* another
    /// app's bundle, whereas a real status-item app is a top-level bundle of its own.
    static func ownsStatusItemPlausibly(_ app: NSRunningApplication) -> Bool {
        guard let path = app.bundleURL?.path else { return false }
        return !path.contains(".app/Contents/")
    }

    // MARK: - Per app

    struct AppScanResult: Sendable {
        var appName: String
        var targets: [Target]
        var duration: TimeInterval
        var truncated: Bool
    }

    private static func scanApp(
        pid: pid_t,
        appName: String,
        windows: [ScreenWindow],
        allWindows: [ScreenWindow],
        isFrontmost: Bool,
        options: AXScanOptions
    ) -> AppScanResult {
        let started = Date()
        // Windowless apps get the tight budget: one attribute read, not a tree walk.
        let extrasOnly = windows.isEmpty
        let deadline = started.addingTimeInterval(
            extrasOnly ? options.extrasOnlyDeadline : options.perAppDeadline
        )

        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(extrasOnly ? options.extrasOnlyTimeout : options.messagingTimeout)
        // Must happen before reading any window, or Chromium-based apps hand back an
        // empty tree and we silently see nothing in Chrome, Slack or VS Code.
        //
        // Only for apps that actually have windows on screen: it asks an app to build
        // its whole accessibility tree, which is wasted work (and an unnecessary poke)
        // for a background app we are only going to ask about its status item.
        if !windows.isEmpty {
            app.enableManualAccessibility()
        }

        var budget = Budget(remaining: options.maxElementsPerApp, deadline: deadline)
        var targets: [Target] = []

        // Drop windows that are completely buried before doing any AX work on them.
        // Walking a hidden window costs exactly as much as a visible one and every
        // target it yields is discarded afterwards, so this is the single biggest
        // saving in the whole scan.
        let visibleWindows = windows.filter { !Occlusion.isFullyOccluded($0, by: allWindows) }

        // Index the on-screen windows so each AX window can find its z-order.
        var screenWindowByID: [CGWindowID: ScreenWindow] = [:]
        for window in visibleWindows { screenWindowByID[window.id] = window }

        for axWindow in app.windows {
            guard !budget.isExhausted else { break }
            guard let screenWindow = match(axWindow: axWindow, to: visibleWindows, byID: screenWindowByID)
            else { continue }

            collect(
                from: axWindow,
                clip: screenWindow.bounds,
                window: screenWindow,
                appName: appName,
                pid: pid,
                options: options,
                budget: &budget,
                into: &targets
            )
        }

        // The menu bar is not a window in the AX sense, so it needs its own pass. Only
        // the frontmost app owns the visible menu bar.
        if options.includeMenuBar, isFrontmost, !budget.isExhausted,
           let menuBar = app.element(kAXMenuBarAttribute as String) {
            collectMenuBar(
                menuBar,
                appName: appName,
                pid: pid,
                options: options,
                budget: &budget,
                into: &targets
            )
        }

        // Status items (Control Center, Wi-Fi, battery, third-party menu bar apps)
        // are not windows and never appear under AXWindows. They hang off a separate
        // AXExtrasMenuBar attribute, so without this pass the entire right-hand end of
        // the menu bar is unreachable.
        if options.includeMenuBar, !budget.isExhausted,
           let extras = app.element("AXExtrasMenuBar") {
            collectMenuBar(
                extras,
                appName: appName,
                pid: pid,
                options: options,
                budget: &budget,
                into: &targets
            )
        }

        return AppScanResult(
            appName: appName,
            targets: targets,
            duration: Date().timeIntervalSince(started),
            truncated: !extrasOnly && budget.isExhausted
        )
    }

    /// Ties an AX window to the `CGWindowListCopyWindowInfo` entry for the same window.
    ///
    /// The private `_AXUIElementGetWindow` is exact when it works. The bounds fallback
    /// exists because it is private API and could stop resolving on a future OS.
    private static func match(
        axWindow: AXElement,
        to windows: [ScreenWindow],
        byID index: [CGWindowID: ScreenWindow]
    ) -> ScreenWindow? {
        if let identifier = axWindow.windowID, let window = index[identifier] { return window }
        guard let frame = axWindow.frame else { return nil }
        return windows.first { window in
            abs(window.bounds.origin.x - frame.origin.x) < 2
                && abs(window.bounds.origin.y - frame.origin.y) < 2
                && abs(window.bounds.width - frame.width) < 2
        }
    }

    /// Element and time budget, threaded through the traversal so both limits are
    /// checked in the same place.
    struct Budget {
        var remaining: Int
        var deadline: Date
        var hitLimit = false

        var isExhausted: Bool {
            mutating get {
                if remaining <= 0 || Date() > deadline {
                    hitLimit = true
                    return true
                }
                return false
            }
        }

        mutating func consume() { remaining -= 1 }
    }

    // MARK: - Traversal

    private static func collect(
        from root: AXElement,
        clip: CGRect,
        window: ScreenWindow,
        appName: String,
        pid: pid_t,
        options: AXScanOptions,
        budget: inout Budget,
        into targets: inout [Target]
    ) {
        // Breadth-first: shallower elements are the ones a user is most likely to want,
        // so if the budget runs out mid-app the hints that survive are the useful ones.
        var queue: [(element: AXElement, depth: Int)] = [(root, 0)]

        while !queue.isEmpty {
            guard !budget.isExhausted else { return }
            let (element, depth) = queue.removeFirst()
            budget.consume()

            let role = element.role

            if let target = makeTarget(
                from: element,
                role: role,
                clip: clip,
                window: window,
                appName: appName,
                pid: pid,
                options: options
            ) {
                targets.append(target)
            }

            guard depth < options.maxDepth else { continue }
            if let role, leafRoles.contains(role) { continue }

            // Children entirely outside the visible window are scrolled out of view.
            // Skipping them here is what keeps long documents from blowing the budget.
            for child in element.children {
                if let childFrame = child.frame, !childFrame.intersects(clip) { continue }
                queue.append((child, depth + 1))
            }
        }
    }

    private static func makeTarget(
        from element: AXElement,
        role: String?,
        clip: CGRect,
        window: ScreenWindow,
        appName: String,
        pid: pid_t,
        options: AXScanOptions
    ) -> Target? {
        guard let role else { return nil }
        guard actionableRoles.contains(role) || element.supportsPress else { return nil }
        guard element.isEnabled else { return nil }
        guard let frame = element.frame else { return nil }
        guard frame.width >= options.minimumTargetSize,
              frame.height >= options.minimumTargetSize else { return nil }
        // Clip rather than reject: a button half-scrolled off the edge is still worth
        // hinting, but its hint belongs on the visible half.
        guard let visible = Geometry.clamp(frame, to: clip) else { return nil }

        let label = element.windowControlName ?? element.label ?? friendlyRoleName(role)

        return Target(
            frame: visible,
            label: label,
            role: role,
            source: .accessibility,
            handle: element,
            appName: appName,
            pid: pid,
            windowID: window.id,
            zIndex: window.zIndex
        )
    }

    private static func collectMenuBar(
        _ menuBar: AXElement,
        appName: String,
        pid: pid_t,
        options: AXScanOptions,
        budget: inout Budget,
        into targets: inout [Target]
    ) {
        for item in menuBar.children {
            guard !budget.isExhausted else { return }
            budget.consume()
            guard let frame = item.frame, frame.width >= options.minimumTargetSize else { continue }
            guard let label = item.label else { continue }

            targets.append(
                Target(
                    frame: frame,
                    label: label,
                    role: item.role ?? "AXMenuBarItem",
                    source: .accessibility,
                    handle: item,
                    appName: appName,
                    pid: pid,
                    // No window id and a z-index ahead of every window: the menu bar is
                    // drawn above everything and can never be occluded.
                    windowID: nil,
                    zIndex: -1
                )
            )
        }
    }

    /// Fallback label for a control with no title at all, so it still gets a number
    /// rather than vanishing. "Button" beats an empty chip.
    private static func friendlyRoleName(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }
}
