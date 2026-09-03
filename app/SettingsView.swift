import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var page: Page = CommandLine.arguments.contains("--permission-recovery")
        ? .permissions
        : .touch

    enum Page: CaseIterable, Identifiable {
        case touch
        case control
        case voice
        case permissions

        var id: Self { self }

        var title: String {
            switch self {
            case .touch: return L("Touch")
            case .control: return L("Controls")
            case .voice: return L("Voice")
            case .permissions: return L("Permissions")
            }
        }

        var symbol: String {
            switch self {
            case .permissions: return "lock.shield"
            case .touch: return "hand.draw"
            case .control: return "gamecontroller"
            case .voice: return "waveform"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch page {
                    case .permissions: PermissionSettingsView(model: model)
                    case .touch: TouchSettingsView(model: model)
                    case .control: ControlSettingsView()
                    case .voice:
                        VoiceSettingsView(model: model) { page = .permissions }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 620, idealHeight: 700)
        .onAppear { model.startRefreshing() }
        .onDisappear { model.stopRefreshing() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SiriRemote")
                .font(.system(size: 21, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

            ForEach(Page.allCases) { item in
                Button {
                    page = item
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .frame(width: 20)
                        Text(item.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 15, weight: page == item ? .semibold : .regular))
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(page == item ? Color.accentColor.opacity(0.18) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connectionColor)
                .frame(width: 9, height: 9)
            Text(connectionTitle)
                .font(.title3.weight(.semibold))
            if model.secondRemoteIgnored {
                Label(L("A second remote was ignored"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let message = model.configSaveError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 58)
    }

    private var connectionColor: Color {
        if !model.readiness.accessibilityGranted { return .orange }
        if !model.readiness.hidInputAvailable { return .orange }
        return model.connected ? .green : .secondary
    }

    private var connectionTitle: String {
        if !model.readiness.accessibilityGranted { return L("Accessibility Permission Required") }
        if !model.readiness.hidInputAvailable { return L("Restoring Input…") }
        return model.connected ? L("Connected") : L("Not Connected")
    }
}

private struct PermissionSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L("System Permissions")) {
                StatusRow(
                    title: L("Accessibility"),
                    ready: model.readiness.accessibilityGranted,
                    detail: model.readiness.accessibilityGranted
                        ? L("Authorized")
                        : L("Authorization Required"),
                    actionTitle: model.readiness.accessibilityGranted
                        ? nil
                        : L("Open System Settings"),
                    action: model.readiness.accessibilityGranted
                        ? nil
                        : SystemReadiness.openAccessibilitySettings
                )
            }

            Section(L("Startup")) {
                HStack(spacing: 12) {
                    Text(L("Open at Login"))
                    Spacer(minLength: 16)

                    if model.launchAtLoginRequiresApproval {
                        Label(L("Awaiting System Approval"), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }

                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLoginEnabled($0) }
                    ))
                    .labelsHidden()
                    .disabled(!model.launchAtLoginAvailable)
                }
                .settingsRow()
            }

            if let error = model.configLoadError {
                Section(L("Configuration")) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .alert(
            L("Couldn’t Change Open at Login"),
            isPresented: Binding(
                get: { model.launchAtLoginError != nil },
                set: { if !$0 { model.clearLaunchAtLoginError() } }
            )
        ) {
            Button(L("OK")) { model.clearLaunchAtLoginError() }
        } message: {
            Text(model.launchAtLoginError ?? L("Unknown Error"))
        }
    }
}

private struct TouchSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section(L("Switches")) {
                Toggle(L("Trackpad"), isOn: Binding(
                    get: { model.touchEnabled },
                    set: { value in model.updateSettings { $0.touchEnabled = value } }
                ))
                .settingsRow()
                Toggle(L("Circular Scroll"), isOn: Binding(
                    get: { model.circularScrollEnabled },
                    set: { value in
                        model.updateSettings { $0.circularScroll.enabled = value }
                    }
                ))
                .settingsRow()
            }

            Section(L("Speed")) {
                LabeledContent(L("Pointer Speed")) {
                    TickedSlider(value: Binding(
                        get: { model.cursorSpeed },
                        set: { value in model.updateSettings { $0.cursorSpeed = value } }
                    ), range: 0.2...1.8, tickCount: 5)
                    .frame(width: 330)
                }
                .settingsRow()
                LabeledContent(L("Scroll Speed")) {
                    TickedSlider(value: Binding(
                        get: { model.scrollSpeed },
                        set: { value in
                            model.updateSettings { $0.circularScroll.pixelsPerRadian = value }
                        }
                    ), range: 25...225, tickCount: 5)
                    .frame(width: 330)
                }
                .settingsRow()
                HStack {
                    Spacer(minLength: 0)
                    Button(L("Restore Defaults")) { model.resetDefaults() }
                }
                .settingsRow()
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

private struct ControlSettingsView: View {
    var body: some View {
        Form {
            Section(L("Button Actions")) {
                LabeledContent(L("Power Button"), value: L("Lock Screen")).settingsRow()
                LabeledContent(
                    L("TV Button"),
                    value: L("Hold to switch apps; use Left/Right to choose")
                ).settingsRow()
                LabeledContent(L("Center Button"), value: L("Return")).settingsRow()
                LabeledContent(
                    L("Back Button"),
                    value: L("Delete (hold to repeat)")
                ).settingsRow()
                LabeledContent(
                    L("Up / Down / Left / Right"),
                    value: L("Arrow Keys")
                ).settingsRow()
                LabeledContent(
                    L("Play/Pause Button"),
                    value: L("Play or pause media")
                ).settingsRow()
                LabeledContent(L("Mute Button"), value: L("Mute or unmute")).settingsRow()
                LabeledContent(
                    L("Volume Up/Down Buttons"),
                    value: L("Adjust system volume")
                ).settingsRow()
                LabeledContent(
                    L("Voice Button"),
                    value: L("Tap to send; hold for voice input")
                ).settingsRow()
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}

/// SwiftUI's macOS 13 Slider supports stepping but does not expose native tick marks. Keep the
/// bridge limited to one NSSlider while SwiftUI remains the sole owner of the stored value.
private struct TickedSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.numberOfTickMarks = tickCount
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = tickCount
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) { self.value = value }

        @objc func valueChanged(_ sender: NSSlider) {
            guard value.wrappedValue != sender.doubleValue else { return }
            value.wrappedValue = sender.doubleValue
        }
    }
}

private struct VoiceSettingsView: View {
    @ObservedObject var model: SettingsModel
    let showPermissions: () -> Void

    var body: some View {
        Form {
            Section(L("Connections")) {
                StatusRow(
                    title: L("Apple TV Remote"),
                    ready: remoteReady,
                    detail: remoteConnectionDetail,
                    actionTitle: remoteActionTitle,
                    action: remoteAction
                )
                StatusRow(
                    title: "PacketLogger",
                    ready: model.readiness.packetLoggerInstalled,
                    detail: model.readiness.packetLoggerInstalled
                        ? L("Installed")
                        : L("Installation Required"),
                    actionTitle: model.readiness.packetLoggerInstalled ? nil : L("Get"),
                    action: model.readiness.packetLoggerInstalled
                        ? nil
                        : SystemReadiness.openPacketLoggerDownload
                )
                StatusRow(
                    title: L("Doubao Input Method"),
                    ready: model.readiness.doubaoInputSourceStatus == .enabled,
                    detail: doubaoDetail,
                    actionTitle: doubaoActionTitle,
                    action: doubaoAction
                )
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }

    private var remoteReady: Bool {
        model.readiness.accessibilityGranted
            && model.readiness.hidInputAvailable
            && model.connected
    }

    private var remoteConnectionDetail: String {
        if !model.readiness.accessibilityGranted { return L("Accessibility Permission Required") }
        if !model.readiness.hidInputAvailable { return L("Restoring Input…") }
        return model.connected ? L("Connected") : L("Not Detected")
    }

    private var remoteActionTitle: String? {
        if !model.readiness.accessibilityGranted { return L("View Permissions") }
        if !model.readiness.hidInputAvailable || model.connected { return nil }
        return L("Bluetooth Settings")
    }

    private var remoteAction: (() -> Void)? {
        if !model.readiness.accessibilityGranted { return showPermissions }
        if !model.readiness.hidInputAvailable || model.connected { return nil }
        return SystemReadiness.openBluetoothSettings
    }

    private var doubaoDetail: String {
        switch model.readiness.doubaoInputSourceStatus {
        case .notInstalled: return L("Not Installed")
        case .disabled: return L("Not Enabled")
        case .enabled: return L("Enabled")
        }
    }

    private var doubaoActionTitle: String? {
        switch model.readiness.doubaoInputSourceStatus {
        case .notInstalled: return L("Download")
        case .disabled: return L("Open Settings")
        case .enabled: return nil
        }
    }

    private var doubaoAction: (() -> Void)? {
        switch model.readiness.doubaoInputSourceStatus {
        case .notInstalled: return SystemReadiness.openDoubaoDownload
        case .disabled: return SystemReadiness.openKeyboardSettings
        case .enabled: return nil
        }
    }
}

private struct StatusRow: View {
    let title: String
    let ready: Bool
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if let action, let actionTitle {
            Button(action: action) {
                rowContent(actionTitle: actionTitle)
            }
            .buttonStyle(.plain)
        } else {
            rowContent(actionTitle: nil)
        }
    }

    private func rowContent(actionTitle: String?) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 16)
            Label(detail, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ready ? Color.green : Color.orange)
            if let actionTitle {
                Text(actionTitle)
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .settingsRow()
    }
}

private extension View {
    func settingsRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
    }
}
