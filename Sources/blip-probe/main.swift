import AppKit
import BlipCore
import BlipKit
import Foundation

// Headless probe for the scan pipeline.
//
// The GUI is a bad place to debug coverage and performance: hints are transient, and
// "why did this button not get a number" is unanswerable by looking at an overlay. This
// runs the exact same scanners and prints what they found.
//
//   swift run blip-probe --timings
//   swift run blip-probe --app Safari
//   swift run blip-probe --ocr --json > /tmp/scan.json

struct Options {
    var json = false
    var includeOCR = false
    var showTimings = false
    var appFilter: String?
    var limit = 60
    var dumpWindows = false
    var repeatCount = 1
}

func parseOptions() -> Options {
    var options = Options()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--json": options.json = true
        case "--ocr": options.includeOCR = true
        case "--timings": options.showTimings = true
        case "--all": options.limit = .max
        case "--windows": options.dumpWindows = true
        case "--repeat": options.repeatCount = iterator.next().flatMap(Int.init) ?? 1
        case "--app": options.appFilter = iterator.next()
        case "--limit": options.limit = iterator.next().flatMap(Int.init) ?? options.limit
        case "--help", "-h":
            print("""
            usage: blip-probe [--json] [--ocr] [--timings] [--app NAME] [--limit N] [--all]

              --json      machine-readable output
              --ocr       also run the Vision pass (needs Screen Recording)
              --timings   per-app and per-phase wall times
              --app NAME  only show targets from apps whose name contains NAME
              --limit N   cap printed targets (default 60)
              --all       no cap
              --windows   dump enumerated windows and AX window matching
              --repeat N  run the scan N times in one process (warm-connection timing)
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(argument)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return options
}

struct TargetDTO: Encodable {
    var hint: String?
    var label: String
    var role: String?
    var source: String
    var app: String
    var x: Int, y: Int, width: Int, height: Int
    var windowID: UInt32?
    var zIndex: Int

    init(_ target: Target) {
        hint = target.hint
        label = target.label
        role = target.role
        source = target.source.rawValue
        app = target.appName
        x = Int(target.frame.origin.x)
        y = Int(target.frame.origin.y)
        width = Int(target.frame.width)
        height = Int(target.frame.height)
        windowID = target.windowID
        zIndex = target.zIndex
    }
}

struct ReportDTO: Encodable {
    var accessibilityCount: Int
    var ocrCount: Int
    var windowCount: Int
    var accessibilityDuration: Double
    var ocrDuration: Double?
    var ocrError: String?
    var truncatedApps: [String]
    var perAppTimings: [String: Double]
    var targets: [TargetDTO]
}

let options = parseOptions()

// Accessibility is non-negotiable. Note that when run from a terminal the grant belongs
// to the terminal app, not to this binary.
guard Permissions.hasAccessibility else {
    FileHandle.standardError.write("""
    Accessibility permission is not granted to this process.

    Running under a terminal means the grant is attributed to the terminal app itself.
    Add it in: System Settings > Privacy & Security > Accessibility

    """.data(using: .utf8)!)
    exit(1)
}

if options.includeOCR, !Permissions.hasScreenRecording {
    FileHandle.standardError.write("warning: Screen Recording not granted; skipping OCR\n".data(using: .utf8)!)
}

if options.dumpWindows {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let windows = WindowEnumerator.onScreenWindows(excludingPID: ownPID)
    print("\(windows.count) on-screen windows:\n")
    for window in windows {
        print("  z=\(window.zIndex) layer=\(window.layer) id=\(window.id) pid=\(window.pid) "
            + "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
            + "@\(Int(window.bounds.origin.x)),\(Int(window.bounds.origin.y))  \(window.appName)")
    }

    print("\nAX window matching per app:")
    for (pid, appWindows) in WindowEnumerator.groupedByPID(windows) {
        let name = appWindows.first?.appName ?? "\(pid)"
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(0.25)
        app.enableManualAccessibility()
        let started = Date()
        let axWindows = app.windows
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let ids = axWindows.map { $0.windowID.map(String.init) ?? "nil" }
        let screenIDs = Set(appWindows.map(\.id))
        let matched = axWindows.compactMap(\.windowID).filter { screenIDs.contains($0) }.count
        print("  \(name): cg=\(appWindows.count) ax=\(axWindows.count) matched=\(matched) "
            + "(\(elapsed)ms) axIDs=[\(ids.joined(separator: ","))] cgIDs=\(Array(screenIDs))")
    }
    exit(0)
}

if options.repeatCount > 1 {
    // Same process, repeated scans: shows whether AX connections stay warm between
    // activations, which is what decides if caching the app elements is worth it.
    for pass in 1...options.repeatCount {
        let outcome = await ScanCoordinator.accessibilityPass()
        print("pass \(pass): \(outcome.targets.count) targets in \(Int(outcome.duration * 1000))ms")
    }
    exit(0)
}

let result = await ScanCoordinator.full(includeOCR: options.includeOCR)
var all = result.accessibility.targets + (result.ocr?.targets ?? [])

if let filter = options.appFilter {
    all = all.filter { $0.appName.localizedCaseInsensitiveContains(filter) }
}

if options.json {
    let report = ReportDTO(
        accessibilityCount: result.accessibility.targets.count,
        ocrCount: result.ocr?.targets.count ?? 0,
        windowCount: result.accessibility.windows.count,
        accessibilityDuration: result.accessibility.duration,
        ocrDuration: result.ocr?.duration,
        ocrError: result.ocr?.error,
        truncatedApps: result.accessibility.truncatedApps,
        perAppTimings: result.accessibility.perAppTimings,
        targets: all.map(TargetDTO.init)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(report), encoding: .utf8)!)
} else {
    let axMillis = Int(result.accessibility.duration * 1000)
    print("windows: \(result.accessibility.windows.count)   ax: \(result.accessibility.targets.count) targets in \(axMillis)ms")
    if let ocr = result.ocr {
        print("ocr:     \(ocr.targets.count) targets in \(Int(ocr.duration * 1000))ms"
            + " (capture \(Int(ocr.captureDuration * 1000))ms,"
            + " recognise \(Int(ocr.recognizeDuration * 1000))ms)"
            + (ocr.error.map { "  error: \($0)" } ?? ""))
    }
    if !result.accessibility.truncatedApps.isEmpty {
        print("truncated (hit budget): \(result.accessibility.truncatedApps.joined(separator: ", "))")
    }

    if options.showTimings {
        print("\nper-app AX time:")
        for (app, seconds) in result.accessibility.perAppTimings.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %6dms  %@", Int(seconds * 1000), app))
        }
    }

    // String(format:) ignores width specifiers on %@, so columns are padded by hand.
    func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "\u{2026}" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    print("\n\(min(all.count, options.limit)) of \(all.count) targets:")
    print("  " + pad("hint", 6) + pad("source", 8) + pad("app", 18) + pad("role", 20) + "label")
    for target in all.prefix(options.limit) {
        let label = target.label.replacingOccurrences(of: "\n", with: " ")
        print("  "
            + pad(target.hint ?? "-", 6)
            + pad(target.source.rawValue, 8)
            + pad(target.appName, 18)
            + pad(target.role ?? "-", 20)
            + label.prefix(52))
    }
}
