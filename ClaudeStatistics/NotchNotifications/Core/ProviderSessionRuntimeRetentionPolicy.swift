import Foundation

/// Retention rules for app-style provider sessions whose hook pid belongs to a
/// long-lived host app instead of a one-session CLI process.
enum ProviderSessionRuntimeRetentionPolicy {
    static func shouldKeep(runtime: RuntimeSession, cutoff: Date, now: Date) -> Bool {
        if let pid = runtime.pid, pid > 0 {
            if now.timeIntervalSince(runtime.lastActivityAt) > 10, !LivenessChecker.isProcessAlive(pid) {
                return false
            }
            if LivenessChecker.isProcessStopped(pid) {
                return false
            }
        }

        if runtime.lastActivityAt > cutoff {
            return true
        }

        if runtime.approvalStartedAt.map({ $0 > cutoff }) == true {
            return true
        }
        if runtime.currentToolStartedAt.map({ $0 > cutoff }) == true {
            return true
        }
        if runtime.currentOperation.map({ $0.keepsSessionRunning && $0.startedAt > cutoff }) == true {
            return true
        }
        if runtime.activeTools.values.contains(where: { $0.startedAt > cutoff }) {
            return true
        }
        if runtime.recentlyCompletedTools?.contains(where: {
            now.timeIntervalSince($0.completedAt) < ActiveSession.recentToolsWindow
        }) == true {
            return true
        }

        return false
    }
}
