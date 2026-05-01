import Darwin
import Foundation

if let hookExitCode = HookCLI.runIfNeeded(arguments: CommandLine.arguments) {
    exit(hookExitCode)
}

ClaudeStatisticsApp.main()
