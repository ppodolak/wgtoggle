import AppKit

// Command line: `WGToggle cli <command>` (the `wgtoggle` wrapper) or `WGToggle --diagnose`.
if let i = CommandLine.arguments.firstIndex(of: "cli") {
    exit(CLI.run(Array(CommandLine.arguments[(i + 1)...])))
}
if CommandLine.arguments.contains("--diagnose") {
    if CommandLine.arguments.contains("--print-installer") {   // only the script, nothing else
        // same as the app: only configs not already in the root-owned dir are moved
        print(Helper.installer(user: NSUserName(), moveFrom: listTunnels().map(\.path).filter { !$0.hasPrefix(Helper.configDir + "/") }))
        exit(0)
    }
    exit(CLI.run(["diagnose"]))
}

MainActor.assumeIsolated {   // top-level code runs on the main thread
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
