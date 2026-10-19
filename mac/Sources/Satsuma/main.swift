import AppKit
import SatsumaCore

Settings.load()
let arguments = Array(CommandLine.arguments.dropFirst())

if Cli.handles(arguments) {
    // Headless test modes still run inside NSApplication, because WebKit and PDF printing need a run loop.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        let code = await Cli.run(arguments)
        exit(code)
    }
    app.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
