import Darwin
import Foundation

let hookExitCode = MainActor.assumeIsolated {
    HookCLI.runIfNeeded(arguments: CommandLine.arguments)
}
if let hookExitCode {
    exit(hookExitCode)
}

ClaudeStatisticsApp.main()
