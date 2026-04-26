import Darwin
import Foundation

enum HookCLI {
    private static let providerFlag = "--claude-stats-hook-provider"

    static func runIfNeeded(arguments: [String]) -> Int32? {
        guard let flagIndex = arguments.firstIndex(of: providerFlag) else {
            return nil
        }

        let providerIndex = arguments.index(after: flagIndex)
        guard providerIndex < arguments.endIndex,
              let provider = ProviderKind(rawValue: arguments[providerIndex]) else {
            return 1
        }

        return HookRunner(provider: provider).run()
    }
}

enum HookDefaults {
    static let shortIOTimeoutSeconds = 2
    static let approvalTimeoutMs = 280_000
    static let approvalResponseTimeoutSeconds = approvalTimeoutMs / 1000
    static let maxToolResponseLength = 1200
}

struct HookAction {
    let message: [String: Any]
    let expectsResponse: Bool
    let responseTimeoutSeconds: Int
    let printDecision: ((String?) -> Void)?

    init(
        message: [String: Any],
        expectsResponse: Bool = false,
        responseTimeoutSeconds: Int = HookDefaults.shortIOTimeoutSeconds,
        printDecision: ((String?) -> Void)? = nil
    ) {
        self.message = message
        self.expectsResponse = expectsResponse
        self.responseTimeoutSeconds = responseTimeoutSeconds
        self.printDecision = printDecision
    }
}

struct HookRunner {
    let provider: ProviderKind

    func run() -> Int32 {
        guard let payload = readPayload() else {
            return 0
        }

        let action: HookAction?
        switch provider {
        case .claude:
            action = buildClaudeAction(payload: payload)
        case .codex:
            action = buildCodexAction(payload: payload)
        case .gemini:
            action = buildGeminiAction(payload: payload)
        }

        guard let action else { return 0 }
        logHookDispatch(for: action.message, expectsResponse: action.expectsResponse)
        let decision = socketDecision(
            for: action.message,
            expectsResponse: action.expectsResponse,
            responseTimeoutSeconds: action.responseTimeoutSeconds
        )
        action.printDecision?(decision)
        return 0
    }

    func baseMessage(
        provider: ProviderKind,
        event: String,
        status: String,
        notificationType: String?,
        payload: [String: Any],
        cwd: String?,
        terminalName: String?,
        terminalContext: TerminalContext
    ) -> [String: Any] {
        var message: [String: Any] = [
            "v": 1,
            "auth_token": AttentionBridgeAuth.loadToken() ?? "",
            "provider": provider.rawValue,
            "event": event,
            "status": status,
            "pid": Int(getppid()),
            "expects_response": false,
        ]

        set(&message, "notification_type", notificationType)
        set(&message, "session_id", stringValue(payload["session_id"]))
        set(&message, "cwd", cwd)
        set(&message, "transcript_path", stringValue(payload["transcript_path"]))
        set(&message, "tty", currentTTY(pid: Int(getppid())))
        set(&message, "terminal_name", terminalName)
        set(&message, "terminal_socket", terminalContext.socket)
        set(&message, "terminal_window_id", terminalContext.windowID)
        set(&message, "terminal_tab_id", terminalContext.tabID)
        set(&message, "terminal_surface_id", terminalContext.surfaceID)

        return message
    }

    private func socketDecision(
        for message: [String: Any],
        expectsResponse: Bool,
        responseTimeoutSeconds: Int
    ) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []) else {
            return nil
        }

        let payloadData = data + Data([0x0A])
        let diagnosticContext = HookSocketDiagnosticContext(
            provider: provider,
            event: stringValue(message["event"]) ?? "-",
            sessionId: stringValue(message["session_id"]) ?? "-",
            toolName: stringValue(message["tool_name"]) ?? "-",
            toolUseId: stringValue(message["tool_use_id"]) ?? "-"
        )
        for path in socketPathCandidates {
            guard let responseData = sendToSocket(
                path: path,
                payload: payloadData,
                expectsResponse: expectsResponse,
                responseTimeoutSeconds: responseTimeoutSeconds,
                diagnosticContext: diagnosticContext
            ) else {
                continue
            }

            guard expectsResponse else { return nil }
            guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                DiagnosticLogger.shared.warning(
                    "HookCLI invalid response provider=\(provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) bytes=\(responseData.count)"
                )
                continue
            }
            return stringValue(object["decision"])
        }

        let joinedPaths = socketPathCandidates.joined(separator: ",")
        DiagnosticLogger.shared.warning(
            "HookCLI socket delivery failed provider=\(provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) tool=\(diagnosticContext.toolName) toolUseId=\(diagnosticContext.toolUseId) expectsResp=\(expectsResponse) paths=\(joinedPaths)"
        )
        return nil
    }

    private var socketPathCandidates: [String] {
        [AttentionBridgeAuth.socketPath]
    }

    private func logHookDispatch(for message: [String: Any], expectsResponse: Bool) {
        let event = stringValue(message["event"]) ?? "-"
        let sessionId = stringValue(message["session_id"]) ?? "-"
        let tool = stringValue(message["tool_name"]) ?? "-"
        let toolUseId = stringValue(message["tool_use_id"]) ?? "-"
        let cwd = stringValue(message["cwd"]) ?? "-"
        let tty = stringValue(message["tty"]) ?? "-"
        DiagnosticLogger.shared.verbose(
            "HookCLI dispatch provider=\(provider.rawValue) event=\(event) session=\(sessionId) tool=\(tool) toolUseId=\(toolUseId) expectsResp=\(expectsResponse) cwd=\(cwd) tty=\(tty)"
        )
    }
}

private struct HookSocketDiagnosticContext {
    let provider: ProviderKind
    let event: String
    let sessionId: String
    let toolName: String
    let toolUseId: String
}

struct TerminalContext {
    var socket: String?
    var windowID: String?
    var tabID: String?
    var surfaceID: String?
}

func resolvedHookCWD(payload: [String: Any]) -> String? {
    if let cwd = stringValue(payload["cwd"])?.trimmingCharacters(in: .whitespacesAndNewlines),
       !cwd.isEmpty {
        return cwd
    }

    if let pwd = ProcessInfo.processInfo.environment["PWD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !pwd.isEmpty {
        return pwd
    }

    let currentDirectory = FileManager.default.currentDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return currentDirectory.isEmpty ? nil : currentDirectory
}

func set(_ object: inout [String: Any], _ key: String, _ value: Any?) {
    guard let value else { return }
    object[key] = value
}

private func readPayload() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func printCodexPermissionDecision(_ decision: String?) {
    switch decision {
    case "allow":
        printJSON([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                ],
            ],
        ])
    case "deny":
        printJSON([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "deny",
                    "message": "Denied via Claude Statistics",
                ],
            ],
        ])
    default:
        printJSON([:])
    }
}

func printClaudePermissionDecision(_ decision: String?) {
    switch decision {
    case "allow":
        printJSON([
            "behavior": "allow",
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                ],
            ],
        ])
    case "deny":
        printJSON([
            "behavior": "deny",
            "message": "Denied via Claude Statistics",
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "deny",
                    "message": "Denied via Claude Statistics",
                ],
            ],
        ])
    default:
        printJSON([:])
    }
}

func normalizedToolUseId(payload: [String: Any], toolInput: [String: Any]?) -> String? {
    for key in ["tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id", "callId", "id"] {
        if let value = stringValue(payload[key]) {
            return value
        }
    }

    if let toolInput {
        for key in ["tool_use_id", "toolUseId", "tool_call_id", "toolCallId", "call_id", "callId", "id"] {
            if let value = stringValue(toolInput[key]) {
                return value
            }
        }
    }

    return nil
}

func toolNameValue(_ payload: [String: Any]) -> String? {
    for key in ["tool_name", "toolName", "name", "displayName"] {
        if let value = stringValue(payload[key]) {
            return value
        }
    }

    for key in ["tool", "functionCall", "function_call"] {
        if let nested = dictionaryValue(payload[key]),
           let value = toolNameValue(nested) {
            return value
        }
    }

    return nil
}

func toolResponseText(payload: [String: Any]) -> String? {
    for key in ["tool_response", "tool_result", "result", "response", "output", "resultDisplay"] {
        if let value = firstText(payload[key]) {
            return value
        }
    }
    return nil
}

func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}

func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func nestedDictionaryValue(_ value: Any?, preferredKeys: [String]) -> [String: Any]? {
    guard let object = dictionaryValue(value) else { return nil }
    for key in preferredKeys {
        if let nested = dictionaryValue(object[key]) {
            return nested
        }
    }
    return object
}

func firstText(_ value: Any?) -> String? {
    guard let value else { return nil }

    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return isNoiseText(trimmed) ? nil : (trimmed.isEmpty ? nil : trimmed)
    }

    if let array = value as? [Any] {
        for item in array {
            if let text = firstText(item) {
                return text
            }
        }
        return nil
    }

    if let dictionary = value as? [String: Any] {
        for key in ["message", "text", "content", "summary", "error", "reason", "warning", "prompt"] {
            if let text = firstText(dictionary[key]) {
                return text
            }
        }
        for (key, item) in dictionary where !["type", "kind", "status", "role", "mime_type", "content_type"].contains(key) {
            if let text = firstText(item) {
                return text
            }
        }
        return nil
    }

    if value is NSNull {
        return nil
    }

    let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    return isNoiseText(text) ? nil : (text.isEmpty ? nil : text)
}

private func isNoiseText(_ value: String) -> Bool {
    ["text", "json", "stdout", "output", "---", "--", "...", "…"].contains(value.lowercased())
}

func canonicalTerminalName(_ terminalName: String?) -> String? {
    let env = ProcessInfo.processInfo.environment
    if env["KITTY_WINDOW_ID"] != nil || env["KITTY_LISTEN_ON"] != nil {
        return "kitty"
    }
    if env["WEZTERM_PANE"] != nil || env["WEZTERM_UNIX_SOCKET"] != nil {
        return "wezterm"
    }
    if env["ITERM_SESSION_ID"] != nil {
        return "iTerm2"
    }
    return terminalName
}

func terminalContextForCodex(event: String, terminalName: String?, cwd: String?) -> TerminalContext {
    terminalContext(
        event: event,
        terminalName: terminalName,
        cwd: cwd,
        ghosttyFrontmostEvents: ["SessionStart", "UserPromptSubmit"],
        ghosttyFallbackMode: .uniqueDirectoryMatch
    )
}

func terminalContextForClaude(event: String, terminalName: String?, cwd: String?) -> TerminalContext {
    terminalContext(
        event: event,
        terminalName: terminalName,
        cwd: cwd,
        ghosttyFrontmostEvents: ["SessionStart", "UserPromptSubmit"],
        ghosttyFallbackMode: .uniqueDirectoryMatch
    )
}

func terminalContextForGemini(event: String, terminalName: String?, cwd: String?) -> TerminalContext {
    terminalContext(
        event: event,
        terminalName: terminalName,
        cwd: cwd,
        ghosttyFrontmostEvents: ["BeforeAgent", "BeforeModel", "BeforeTool", "SessionStart"],
        ghosttyFallbackMode: .uniqueDirectoryMatch
    )
}

private enum GhosttyFallbackMode {
    case disabled
    case uniqueDirectoryMatch
}

private func terminalContext(
    event: String,
    terminalName: String?,
    cwd: String?,
    ghosttyFrontmostEvents: Set<String>,
    ghosttyFallbackMode: GhosttyFallbackMode
) -> TerminalContext {
    let env = ProcessInfo.processInfo.environment
    let normalized = (terminalName ?? "").lowercased()

    if env["KITTY_WINDOW_ID"] != nil || env["KITTY_LISTEN_ON"] != nil {
        return TerminalContext(
            socket: env["KITTY_LISTEN_ON"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["KITTY_WINDOW_ID"]
        )
    }

    if env["WEZTERM_PANE"] != nil || env["WEZTERM_UNIX_SOCKET"] != nil {
        return TerminalContext(
            socket: env["WEZTERM_UNIX_SOCKET"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["WEZTERM_PANE"]
        )
    }

    if normalized.contains("iterm") {
        let session = env["ITERM_SESSION_ID"] ?? ""
        let stableID = session.split(separator: ":", maxSplits: 1).last.map(String.init)
        return TerminalContext(socket: nil, windowID: nil, tabID: nil, surfaceID: stableID)
    }

    if normalized.contains("kitty") {
        return TerminalContext(
            socket: env["KITTY_LISTEN_ON"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["KITTY_WINDOW_ID"]
        )
    }

    if normalized.contains("wezterm") {
        return TerminalContext(
            socket: env["WEZTERM_UNIX_SOCKET"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["WEZTERM_PANE"]
        )
    }

    guard normalized.contains("ghostty") else {
        return TerminalContext()
    }

    if ghosttyFrontmostEvents.contains(event),
       let frontmost = ghosttyFrontmostContext(cwd: cwd, requireFrontmostApp: false) {
        return frontmost
    }

    guard ghosttyFallbackMode == .uniqueDirectoryMatch else {
        return TerminalContext()
    }

    return ghosttyUniqueDirectoryMatch(cwd: cwd) ?? TerminalContext()
}

private func ghosttyFrontmostContext(cwd: String?, requireFrontmostApp: Bool) -> TerminalContext? {
    let frontmostGuard = requireFrontmostApp ? "if not frontmost then return \"\"\n    " : ""
    let script = """
    tell application id "com.mitchellh.ghostty"
        \(frontmostGuard)try
            set w to front window
            set tabRef to selected tab of w
            set terminalRef to focused terminal of tabRef
            set outputLine to (id of w as text) & (ASCII character 31) & (id of tabRef as text) & (ASCII character 31) & (id of terminalRef as text) & (ASCII character 31) & (working directory of terminalRef as text)
            return outputLine
        end try
    end tell
    return ""
    """

    let diag = commandOutputDiagnostic("/usr/bin/osascript", args: ["-e", script])
    guard let output = diag.stdout, diag.exitCode == 0 else {
        hookGhosttyLog("frontmost osascript failed cwd=\(cwd ?? "-") requireFrontmost=\(requireFrontmostApp) exit=\(diag.exitCode.map(String.init) ?? "-") stderr=\(diag.stderr.debugDescription)")
        return nil
    }

    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "\u{1F}", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        hookGhosttyLog("frontmost parse mismatch fields=\(parts.count) raw=\(trimmed.debugDescription)")
        return nil
    }

    let resolvedCWD = normalizePath(cwd)
    let resolvedTerminalCWD = normalizePath(String(parts[3]))
    guard resolvedTerminalCWD == resolvedCWD else {
        hookGhosttyLog(
            "frontmost cwd mismatch hook=\(resolvedCWD ?? "-") ghostty=\(resolvedTerminalCWD ?? "-") raw=\(String(parts[3]).debugDescription)"
        )
        return nil
    }

    hookGhosttyLog("frontmost matched window=\(String(parts[0])) tab=\(String(parts[1])) stable=\(String(parts[2])) cwd=\(resolvedTerminalCWD ?? "-")")
    return TerminalContext(
        socket: nil,
        windowID: nonEmpty(String(parts[0])),
        tabID: nonEmpty(String(parts[1])),
        surfaceID: nonEmpty(String(parts[2]))
    )
}

private func ghosttyUniqueDirectoryMatch(cwd: String?) -> TerminalContext? {
    let script = """
    tell application id "com.mitchellh.ghostty"
        set outputLines to {}
        repeat with w in every window
            set windowID to id of w as text
            repeat with tabRef in every tab of w
                set tabID to id of tabRef as text
                set terminalRef to focused terminal of tabRef
                set terminalID to id of terminalRef as text
                set terminalWD to working directory of terminalRef as text
                set end of outputLines to windowID & (ASCII character 31) & tabID & (ASCII character 31) & terminalID & (ASCII character 31) & terminalWD
            end repeat
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to ""
        return outputText
    end tell
    """

    guard let output = commandOutput("/usr/bin/osascript", args: ["-e", script]) else {
        hookGhosttyLog("unique cwd scan returned no output cwd=\(cwd ?? "-")")
        return nil
    }

    let target = normalizePath(cwd)
    var matches: [TerminalContext] = []
    for line in output.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard parts.count == 4 else { continue }
        guard normalizePath(String(parts[3])) == target else { continue }
        matches.append(
            TerminalContext(
                socket: nil,
                windowID: nonEmpty(String(parts[0])),
                tabID: nonEmpty(String(parts[1])),
                surfaceID: nonEmpty(String(parts[2]))
            )
        )
    }

    hookGhosttyLog("unique cwd scan target=\(target ?? "-") matches=\(matches.count)")
    return matches.count == 1 ? matches[0] : nil
}

private func currentTTY(pid: Int) -> String? {
    if let tty = normalizeTTY(ttyname(FileHandle.standardInput.fileDescriptor)) {
        return tty
    }

    if let envTTY = normalizeTTY(ProcessInfo.processInfo.environment["TTY"]) {
        return envTTY
    }

    guard let output = commandOutput("/bin/ps", args: ["-o", "tty=", "-p", String(pid)], timeout: 0.5) else {
        return nil
    }
    return normalizeTTY(output)
}

private func normalizeTTY(_ value: UnsafePointer<CChar>?) -> String? {
    guard let value else { return nil }
    return normalizeTTY(String(cString: value))
}

private func normalizeTTY(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "??", trimmed != "-" else { return nil }
    return trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
}

private func normalizePath(_ value: String?) -> String? {
    guard let value else { return nil }
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if text.hasPrefix("file://") {
        if let decoded = URL(string: text)?.path.removingPercentEncoding {
            text = decoded
        } else {
            text = String(text.dropFirst(7))
        }
    }

    return URL(fileURLWithPath: text)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

private func sendToSocket(
    path: String,
    payload: Data,
    expectsResponse: Bool,
    responseTimeoutSeconds: Int,
    diagnosticContext: HookSocketDiagnosticContext
) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        let code = errno
        DiagnosticLogger.shared.warning(
            "HookCLI socket create failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) errno=\(code) reason=\(String(cString: strerror(code)))"
        )
        return nil
    }
    defer { close(fd) }

    var sendTimeout = timeval(tv_sec: HookDefaults.shortIOTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    if expectsResponse {
        var receiveTimeout = timeval(tv_sec: responseTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    let pathBytes = Array(path.utf8CString)
    guard pathBytes.count <= maxLength else { return nil }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { destination in
            destination.initialize(repeating: 0, count: maxLength)
            _ = pathBytes.withUnsafeBufferPointer { source in
                memcpy(destination, source.baseAddress, pathBytes.count)
            }
        }
    }

    let connectResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        let code = errno
        DiagnosticLogger.shared.warning(
            "HookCLI socket connect failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path) errno=\(code) reason=\(String(cString: strerror(code)))"
        )
        // App not listening (ECONNREFUSED) or socket file gone (ENOENT) —
        // typically a brief restart window. Persist the payload to the
        // pending dir so AttentionBridge can replay it once the listener is
        // back. Permission requests need a synchronous decision and can't be
        // replayed (the tool will already have run by then), so we only
        // buffer fire-and-forget events.
        if !expectsResponse, code == ECONNREFUSED || code == ENOENT {
            bufferPendingHookPayload(payload: payload, context: diagnosticContext)
        }
        return nil
    }

    guard writeAll(fd: fd, data: payload) else {
        let code = errno
        DiagnosticLogger.shared.warning(
            "HookCLI socket write failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path) errno=\(code) reason=\(String(cString: strerror(code)))"
        )
        // We connected but the write got interrupted (server crashed
        // mid-handshake, EPIPE, etc.). Same recovery path as connect-fail.
        if !expectsResponse {
            bufferPendingHookPayload(payload: payload, context: diagnosticContext)
        }
        return nil
    }

    guard expectsResponse else { return Data() }

    // Host-liveness watchdog: while we block on the long permission-
    // response read (up to 280s), poll `AttentionBridgeAuth.livePid()`
    // every few seconds. If the host died, `shutdown(fd, SHUT_RDWR)`
    // forces our read to return EOF immediately so the CLI doesn't hang.
    let watchdog = HookHostWatchdog(fd: fd)
    watchdog.start()
    defer { watchdog.stop() }

    var response = Data()
    var byte: UInt8 = 0
    while true {
        let bytesRead = withUnsafeMutableBytes(of: &byte) { pointer in
            Darwin.read(fd, pointer.baseAddress, 1)
        }
        if bytesRead < 0 {
            let code = errno
            DiagnosticLogger.shared.warning(
                "HookCLI socket read failed provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path) errno=\(code) reason=\(String(cString: strerror(code)))"
            )
            return nil
        }
        if bytesRead == 0 {
            if watchdog.didInterrupt {
                DiagnosticLogger.shared.warning(
                    "HookCLI host died mid-wait provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path)"
                )
                return nil
            }
            break
        }
        if byte == 0x0A { break }
        response.append(byte)
    }

    if response.isEmpty {
        DiagnosticLogger.shared.warning(
            "HookCLI socket empty response provider=\(diagnosticContext.provider.rawValue) event=\(diagnosticContext.event) session=\(diagnosticContext.sessionId) toolUseId=\(diagnosticContext.toolUseId) path=\(path)"
        )
        return nil
    }

    return response
}

/// Persist a hook payload that couldn't be delivered to the running app's
/// socket. `AttentionBridge.drainPendingMessages()` reads these on next
/// startup and re-injects them through the normal event pipeline.
///
/// File naming: `<unix-millis>-<pid>-<short-uuid>.json`. The leading
/// millis-since-epoch lets the drain side replay in chronological order
/// even if multiple HookCLI instances raced. Atomic write via .tmp + rename
/// so the drain side never sees a half-written file.
private func bufferPendingHookPayload(payload: Data, context: HookSocketDiagnosticContext) {
    let fm = FileManager.default
    guard let pendingDir = AppRuntimePaths.ensurePendingDirectory() else {
        DiagnosticLogger.shared.warning(
            "HookCLI buffer dir create failed event=\(context.event) toolUseId=\(context.toolUseId) path=\(AppRuntimePaths.pendingDirectory)"
        )
        return
    }
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    let pid = ProcessInfo.processInfo.processIdentifier
    let rand = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    let filename = "\(timestampMs)-\(pid)-\(rand).json"
    let finalPath = (pendingDir as NSString).appendingPathComponent(filename)
    let tmpPath = finalPath + ".tmp"
    do {
        try payload.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        try fm.moveItem(atPath: tmpPath, toPath: finalPath)
        DiagnosticLogger.shared.warning(
            "HookCLI buffered to disk provider=\(context.provider.rawValue) event=\(context.event) session=\(context.sessionId) toolUseId=\(context.toolUseId) file=\(filename)"
        )
    } catch {
        try? fm.removeItem(atPath: tmpPath)
        DiagnosticLogger.shared.warning(
            "HookCLI buffer write failed event=\(context.event) toolUseId=\(context.toolUseId) error=\(error.localizedDescription)"
        )
    }
}

private func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return false }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            return false
        }
        return true
    }
}

private struct CommandDiagnostic {
    let stdout: String?
    let stderr: String
    let exitCode: Int32?
}

private func commandOutputDiagnostic(_ executable: String, args: [String], timeout: TimeInterval = 1.0) -> CommandDiagnostic {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.standardOutput = stdoutPipe
    task.standardError = stderrPipe
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    do { try task.run() } catch {
        return CommandDiagnostic(stdout: nil, stderr: "launch_failed:\(error.localizedDescription)", exitCode: nil)
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        _ = finished.wait(timeout: .now() + 0.2)
        return CommandDiagnostic(stdout: nil, stderr: "timeout_\(timeout)s", exitCode: nil)
    }
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdoutText = String(data: stdoutData, encoding: .utf8)
    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
    return CommandDiagnostic(stdout: stdoutText, stderr: stderrText, exitCode: task.terminationStatus)
}

private func commandOutput(_ executable: String, args: [String], timeout: TimeInterval = 1.0) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args

    let stdout = Pipe()
    task.standardOutput = stdout
    task.standardError = Pipe()
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in
        finished.signal()
    }

    do {
        try task.run()
    } catch {
        return nil
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        _ = finished.wait(timeout: .now() + 0.2)
        return nil
    }

    guard task.terminationStatus == 0 else { return nil }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func hookGhosttyLog(_ message: String) {
    DiagnosticLogger.shared.info("Hook ghostty \(message)")
}

/// Background poller that aborts a HookCLI socket read once the host
/// app stops listening. The host's `AttentionBridge.start()` writes its
/// pid to `AttentionBridgeAuth.pidPath` and clears it on stop; if either
/// the file disappears or `kill(pid, 0)` reports ESRCH, we
/// `shutdown(SHUT_RDWR)` the socket so the blocking `read()` returns
/// EOF instead of waiting out the full 280s permission timeout.
final class HookHostWatchdog {
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var interrupted = false
    private let pollInterval: TimeInterval

    init(fd: Int32, pollInterval: TimeInterval = 5.0) {
        self.fd = fd
        self.pollInterval = pollInterval
    }

    var didInterrupt: Bool {
        lock.lock(); defer { lock.unlock() }
        return interrupted
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                self.lock.lock()
                let shouldStop = self.stopped
                self.lock.unlock()
                if shouldStop { return }

                Thread.sleep(forTimeInterval: self.pollInterval)

                self.lock.lock()
                let stillRunning = !self.stopped
                self.lock.unlock()
                if !stillRunning { return }

                if AttentionBridgeAuth.livePid() == nil {
                    self.lock.lock()
                    self.interrupted = true
                    self.stopped = true
                    self.lock.unlock()
                    // Wake the blocking read with EOF. SHUT_RDWR is safer
                    // than close(fd) here because the main thread still
                    // holds fd via `defer { close(fd) }`.
                    shutdown(self.fd, SHUT_RDWR)
                    return
                }
            }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}
