import AppKit

/// Installs the small standard menu set that a nib-less AppKit application does not receive
/// automatically. SwiftUI continues to own the page content; AppKit owns only process-level menu
/// commands and responder-chain routing.
@MainActor
enum ApplicationMenu {
    static func install() {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "SiriRemote")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let about = item(
            L("About SiriRemote"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            target: NSApp
        )
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L("Services"))
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        applicationMenu.addItem(.separator())
        applicationMenu.addItem(item(
            L("Hide SiriRemote"),
            action: #selector(NSApplication.hide(_:)),
            key: "h",
            target: NSApp
        ))
        let hideOthers = item(
            L("Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            target: NSApp
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(item(
            L("Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            target: NSApp
        ))

        applicationMenu.addItem(.separator())
        applicationMenu.addItem(item(
            L("Quit SiriRemote"),
            action: #selector(NSApplication.terminate(_:)),
            key: "q",
            target: NSApp
        ))

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        editMenu.addItem(item(L("Undo"), action: Selector(("undo:")), key: "z"))
        let redo = item(L("Redo"), action: Selector(("redo:")), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(item(L("Cut"), action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item(L("Copy"), action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item(L("Paste"), action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item(L("Select All"), action: #selector(NSText.selectAll(_:)), key: "a"))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        windowMenu.addItem(item(
            L("Close Window"),
            action: #selector(NSWindow.performClose(_:)),
            key: "w"
        ))
        windowMenu.addItem(item(
            L("Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m"
        ))
        windowMenu.addItem(item(L("Zoom"), action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item(
            L("Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            target: NSApp
        ))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private static func item(
        _ title: String,
        action: Selector,
        key: String = "",
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = target
        return menuItem
    }
}
