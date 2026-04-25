import Darwin
import Foundation

/// Pure liveness checks for runtime sessions: PID alive / stopped / terminal
/// context still present. Deliberately stateless and side-effect free so the
/// rules driving "is this CLI still around?" can be unit-tested without
/// constructing the full ActiveSessionsTracker.
enum LivenessChecker {
    static func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    // Detect Ctrl+Z-suspended processes via libproc. SSTOP=4 comes from
    // <sys/proc.h>; PROC_PIDT_SHORTBSDINFO=13 from <sys/proc_info.h>.
    // Returns false on any lookup failure (don't evict on unknown state).
    static func isProcessStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        let bytes = proc_pidinfo(pid, 13, 0, &info, size)
        guard bytes > 0 else { return false }
        return info.pbsi_status == 4
    }

    static func isTerminalContextAlive(tty: String?, terminalSocket: String?) -> Bool {
        let fileManager = FileManager.default
        if let tty, !tty.isEmpty {
            return fileManager.fileExists(atPath: tty)
        }
        if let terminalSocket, !terminalSocket.isEmpty {
            return fileManager.fileExists(atPath: terminalSocket)
        }
        // Be conservative when older runtime records do not have a terminal
        // locator. A live provider pid is stronger evidence than guessing.
        return true
    }

    /// Composite rule used by tracker prune / refresh to decide whether a
    /// runtime session should stay listed. Stays a free function on the
    /// checker so callers without a `RuntimeSession` value (e.g. tests) can
    /// still exercise every branch by passing primitives directly.
    static func shouldKeepSession(
        provider: ProviderKind,
        lastActivityAt: Date,
        pid: Int32?,
        tty: String?,
        terminalSocket: String?,
        cutoff: Date,
        now: Date
    ) -> Bool {
        if let pid, pid > 0 {
            if now.timeIntervalSince(lastActivityAt) > 10, !isProcessAlive(pid) {
                return false
            }
            // Ctrl+Z suspends the CLI. The pid stays but the process is frozen —
            // treat it as gone. `fg` will re-add it via SessionStart if needed.
            if isProcessStopped(pid) {
                return false
            }
        }
        if lastActivityAt > cutoff {
            return true
        }
        guard let pid, pid > 0 else { return false }
        guard isProcessAlive(pid) else { return false }
        return isTerminalContextAlive(tty: tty, terminalSocket: terminalSocket)
    }
}
