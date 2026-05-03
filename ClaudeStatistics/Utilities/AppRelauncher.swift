import AppKit
import Foundation

@MainActor
enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let command = "sleep 0.4; /usr/bin/open -n \(shellQuoted(bundlePath))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()

        NSApp.terminate(nil)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
