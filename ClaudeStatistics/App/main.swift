import Darwin
import Foundation

if let exitCode = HookCLI.runIfNeeded(arguments: CommandLine.arguments) {
    exit(exitCode)
}

ClaudeStatisticsApp.main()
