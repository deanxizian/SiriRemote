import AppKit

if CommandLine.arguments.contains("--verify-capture") {
    let ready = srm_capture_check_service() == 0
    print(ready ? "SIRIREMOTE_CAPTURE_AUTH_OK" : "SIRIREMOTE_CAPTURE_AUTH_FAILED")
    exit(ready ? 0 : 1)
}

if CommandLine.arguments.contains("--verify-config") {
    do {
        _ = try ConfigStore.loadAndValidate(ConfigStore.loadOrBootstrapText())
        print("SIRIREMOTE_CONFIG_OK")
        exit(0)
    } catch {
        fputs("SIRIREMOTE_CONFIG_ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
