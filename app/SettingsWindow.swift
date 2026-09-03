//
//  SettingsWindow.swift
//  SiriRemote (settings UI)
//
//  Hosts the SwiftUI SettingsView as SiriRemote's standard primary App window.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel
    private var closeObserver: NSObjectProtocol?
    private var dockVisibilityGeneration: UInt = 0

    init(model: SettingsModel) { self.model = model }

    deinit {
        if let obs = closeObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let win = NSWindow(contentViewController: hosting)
            win.title = "SiriRemote"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.titlebarAppearsTransparent = false
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = false
            win.tabbingMode = .disallowed
            win.isReleasedWhenClosed = false
            win.collectionBehavior.insert(.moveToActiveSpace)
            win.contentMinSize = NSSize(width: 900, height: 620)
            // Stop readiness polling when the window closes. The window is cached
            // (`isReleasedWhenClosed = false`), so closing only orders it out and SwiftUI's
            // `.onDisappear` does not run, so explicitly stop the lightweight status timer.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { [weak self, weak win] _ in
                MainActor.assumeIsolated {
                    guard let self, let win else { return }
                    self.model.stopRefreshing()
                    self.hideDockIconAfterClosing(win)
                }
            }

            window = win
        }
        model.startRefreshing()
        dockVisibilityGeneration &+= 1
        let presentationGeneration = dockVisibilityGeneration
        // The App behaves like a regular foreground App only while its primary window is open.
        // Restore that role before activation so reopening from the menu bar also restores the
        // Dock icon and the normal application menu.
        NSApp.setActivationPolicy(.regular)
        // A status-menu action can still be inside AppKit's menu-tracking loop. Presenting in that
        // same callback is unreliable immediately after changing from `.accessory` to `.regular`:
        // the Dock icon returns, but the closed window may remain ordered out until a second click.
        // Waiting one main-loop turn lets the menu close before the window is activated.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.dockVisibilityGeneration == presentationGeneration,
                  let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            self.placeOnPrimaryDisplay(window)

            // NSHostingController can publish its final preferred size after the window's first
            // layout pass. Re-centre once more so late sizing cannot expand the window from the
            // centre point into another display.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, window.isVisible else { return }
                self.placeOnPrimaryDisplay(window)
            }
        }
    }

    /// Closing the primary window keeps SiriRemote alive as a menu-bar controller. A generation
    /// token makes the queued policy change deterministic: reopening immediately invalidates the
    /// close request, while an uninterrupted close always removes the Dock icon even if AppKit's
    /// `isVisible` flag has not caught up with `willClose` yet.
    private func hideDockIconAfterClosing(_ closingWindow: NSWindow) {
        dockVisibilityGeneration &+= 1
        let closingGeneration = dockVisibilityGeneration
        DispatchQueue.main.async { [weak self, weak closingWindow] in
            guard let self, let closingWindow,
                  self.dockVisibilityGeneration == closingGeneration,
                  self.window === closingWindow else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// `NSWindow.center()` uses the window's current screen. Because this controller caches its
    /// window, that would also preserve an external-display position after closing. Reposition on
    /// every show using the first NSScreen, which AppKit defines as the display with the menu bar.
    private func placeOnPrimaryDisplay(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 20
        var frame = window.frame

        frame.size.width = min(frame.width, max(1, visibleFrame.width - margin * 2))
        frame.size.height = min(frame.height, max(1, visibleFrame.height - margin * 2))
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrame(frame, display: false)
    }
}
