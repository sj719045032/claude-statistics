import Foundation

enum GhosttyInspector {
    static func focusedTerminalStableID() -> String? {
        let script = """
        tell application id "com.mitchellh.ghostty"
            if not frontmost then return "miss"
            try
                set termRef to focused terminal of selected tab of front window
                return "ok|" & (id of termRef as text)
            end try
        end tell
        return "miss"
        """

        guard let output = runOsascript(script)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              output.hasPrefix("ok|")
        else {
            return nil
        }

        return String(output.dropFirst(3)).nilIfEmpty
    }

    private static func runOsascript(_ source: String) -> String? {
        guard let result = TerminalProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source]
        ),
        result.terminationStatus == 0
        else {
            return nil
        }
        return result.stdout
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
