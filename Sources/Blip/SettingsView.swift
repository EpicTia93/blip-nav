import BlipKit
import SwiftUI

/// Preferences, and — more importantly on first run — the permission checklist.
///
/// The onboarding half is why this window exists at all: both grants live in different
/// panes of System Settings, neither prompt reappears once dismissed, and Accessibility
/// is invisible in its effects until it is granted. A user without this screen is
/// simply stuck with an app that does nothing.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 380)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                LabeledContent("Trigger") {
                    ShortcutRecorder(
                        trigger: triggerBinding,
                        doubleTapWindow: settings.configuration.doubleTapWindow
                    )
                    .frame(height: 22)
                }
                LabeledContent("Double-tap speed") {
                    HStack {
                        Slider(value: doubleTapBinding, in: 0.2...0.6)
                        Text("\(Int(settings.configuration.doubleTapWindow * 1000))ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                // Meaningless for a chord trigger, and dimming it is how the field
                // explains that the two settings belong together.
                .disabled(!settings.configuration.trigger.isDoubleTap)
            } header: {
                Text("Activation")
            } footer: {
                Text("Click the field and press the shortcut you want. To use a double-tapped modifier instead, tap that modifier twice \u{2014} left and right count as different keys. Escape cancels; Delete restores the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Read on-screen text with OCR", isOn: ocrBinding)
                LabeledContent("Languages") {
                    TextField("", text: languagesBinding, prompt: Text("it-IT, en-US"))
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(!settings.configuration.ocrEnabled)
            } header: {
                Text("Recognition")
            } footer: {
                Text("OCR finds text the Accessibility API cannot see, such as canvas-drawn apps and remote desktops. It adds roughly 400ms after the first hints appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Hint size") {
                    HStack {
                        Slider(value: fontSizeBinding, in: 10...20)
                        Text("\(Int(settings.configuration.hintFontSize))pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions

    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            PermissionRow(
                title: "Accessibility",
                detail: "Required. Lets Blip see the controls in other apps, read your trigger key, and click on your behalf.",
                isGranted: permissions.hasAccessibility,
                action: {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )

            PermissionRow(
                title: "Screen Recording",
                detail: "Optional. Needed only for OCR. Without it Blip still finds every control the Accessibility API exposes.",
                isGranted: permissions.hasScreenRecording,
                action: {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                }
            )

            Text("After granting a permission in System Settings, this page updates on its own — but macOS only hands an app its new Accessibility rights on next launch, so quit and reopen Blip.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Bindings

    private var triggerBinding: Binding<Trigger> {
        Binding(
            get: { settings.configuration.trigger },
            set: { settings.configuration.trigger = $0 }
        )
    }

    private var doubleTapBinding: Binding<Double> {
        Binding(
            get: { settings.configuration.doubleTapWindow },
            set: { settings.configuration.doubleTapWindow = $0 }
        )
    }

    private var ocrBinding: Binding<Bool> {
        Binding(
            get: { settings.configuration.ocrEnabled },
            set: { settings.configuration.ocrEnabled = $0 }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { settings.configuration.hintFontSize },
            set: { settings.configuration.hintFontSize = $0 }
        )
    }

    private var languagesBinding: Binding<String> {
        Binding(
            get: { settings.configuration.ocrLanguages.joined(separator: ", ") },
            set: { text in
                settings.configuration.ocrLanguages = text
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !isGranted {
                Button("Grant\u{2026}", action: action)
            }
        }
    }
}
