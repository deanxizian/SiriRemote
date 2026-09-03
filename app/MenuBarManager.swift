import AppKit

final class MenuBarManager {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let connectionItem = NSMenuItem(title: L("Remote: Not Connected"), action: nil,
                                            keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: L("Accessibility: Checking…"), action: nil,
                                             keyEquivalent: "")
    private var connected = false
    private var hidInputAvailable = false
    private var permissionsReady = false

    var onOpenApp: (() -> Void)?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        statusItem.button?.image = Self.makeStatusIcon()
        statusItem.button?.setAccessibilityLabel("SiriRemote")
        rebuild()
        statusItem.menu = menu
    }

    /// A close crop of the remote's upper controls, kept deliberately simple at menu-bar size.
    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let side = rect.height
            let bodyWidth = side * 0.56
            let bottom = side * 0.085
            let top = side * 0.915
            let cornerRadius = side * 0.14
            let left = rect.midX - bodyWidth / 2
            let right = rect.midX + bodyWidth / 2

            let path = CGMutablePath()
            path.move(to: CGPoint(x: left, y: bottom))
            path.addLine(to: CGPoint(x: left, y: top - cornerRadius))
            path.addQuadCurve(
                to: CGPoint(x: left + cornerRadius, y: top),
                control: CGPoint(x: left, y: top)
            )
            path.addLine(to: CGPoint(x: right - cornerRadius, y: top))
            path.addQuadCurve(
                to: CGPoint(x: right, y: top - cornerRadius),
                control: CGPoint(x: right, y: top)
            )
            path.addLine(to: CGPoint(x: right, y: bottom))
            path.closeSubpath()

            let clickpadDiameter = side * 0.37
            path.addEllipse(in: CGRect(
                x: rect.midX - clickpadDiameter / 2,
                y: side * 0.43,
                width: clickpadDiameter,
                height: clickpadDiameter
            ))
            let buttonDiameter = side * 0.14
            let buttonY = side * 0.205
            for offset in [-side * 0.145, side * 0.145] {
                path.addEllipse(in: CGRect(
                    x: rect.midX + offset - buttonDiameter / 2,
                    y: buttonY,
                    width: buttonDiameter,
                    height: buttonDiameter
                ))
            }

            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        return image
    }

    func updateConnectionStatus(connected: Bool) {
        self.connected = connected
        updateConnectionPresentation()
    }

    func updateHIDInputAvailability(_ available: Bool) {
        hidInputAvailable = available
        updateConnectionPresentation()
    }

    func updatePermissionStatus(ready: Bool) {
        permissionsReady = ready
        permissionsItem.title = ready
            ? L("Accessibility: Authorized ✓")
            : L("Accessibility: Authorization Required")
    }

    private func updateConnectionPresentation() {
        if !hidInputAvailable {
            connectionItem.title = L("Remote: Temporarily Unavailable")
        } else {
            connectionItem.title = connected
                ? L("Remote: Connected ✓")
                : L("Remote: Not Connected")
        }
        statusItem.button?.appearsDisabled = !hidInputAvailable || !connected
    }

    private func rebuild() {
        menu.removeAllItems()
        let title = NSMenuItem(title: L("Open SiriRemote"), action: #selector(showMainWindow),
                               keyEquivalent: "")
        title.target = self
        title.image = nil
        menu.addItem(title)
        menu.addItem(.separator())
        connectionItem.isEnabled = false
        permissionsItem.isEnabled = false
        menu.addItem(connectionItem)
        menu.addItem(permissionsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit SiriRemote"), action: #selector(quitApp),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func showMainWindow() { onOpenApp?() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
