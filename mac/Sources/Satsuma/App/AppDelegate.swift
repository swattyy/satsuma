import AppKit
import SatsumaCore

/// The menu bar app: no Dock icon, a status item with Pause/Resume, Shelf, How it works, Settings and Quit.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Interact.current = AppInteraction()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshIcon()
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshIcon()
        }
        DragMonitor.shared.start()
        if !Settings.current.firstRunDone || !DragMonitor.isTrusted { Welcome.show() }
        Log.info("Satsuma \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") started; accessibility \(DragMonitor.isTrusted ? "granted" : "not granted")")
    }

    private func refreshIcon() {
        statusItem?.button?.image = AppIcon.menuBarImage(enabled: Settings.current.enabled)
        statusItem?.button?.toolTip = Settings.current.enabled ? "Satsuma: drag a file, tap \(Settings.current.convertKey.title)" : "Satsuma (paused)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = Settings.current.enabled
        menu.addItem(withTitle: enabled ? "Pause Satsuma" : "Resume Satsuma", action: #selector(toggle), keyEquivalent: "").target = self
        if !DragMonitor.isTrusted {
            menu.addItem(withTitle: "Allow Accessibility…", action: #selector(allow), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Shelf", action: #selector(shelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "How It Works", action: #selector(welcome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Satsuma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggle() {
        Settings.current.enabled.toggle()
        Settings.save()
    }

    @objc private func allow() {
        DragMonitor.requestTrust()
        DragMonitor.openAccessibilitySettings()
    }

    @objc private func shelf() { Shelf.shared.showEmpty() }
    @objc private func welcome() { Welcome.show() }
    @objc private func settings() { SettingsWindow.show() }
}
