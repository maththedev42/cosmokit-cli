//
//  ChatListener.swift
//  cosmokit CLI
//
//  CHAT-08: cosmokit chat listen — long-poll for Agent window messages
//  and answer them automatically using local Claude CLI.
//

import Foundation
import Darwin

public struct ChatListenOptions {
    public var isNewSession: Bool
    public var model: String?
    public var allowEdits: Bool
    public var timeout: TimeInterval
    public var agent: String
    public var isJSON: Bool
    public var workingDir: String
    public var mcpConfigPath: String?

    public init(
        isNewSession: Bool = false,
        model: String? = nil,
        allowEdits: Bool = false,
        timeout: TimeInterval = 600,
        agent: String = "claude",
        isJSON: Bool = false,
        workingDir: String = FileManager.default.currentDirectoryPath,
        mcpConfigPath: String? = nil
    ) {
        self.isNewSession = isNewSession
        self.model = model
        self.allowEdits = allowEdits
        self.timeout = timeout
        self.agent = agent
        self.isJSON = isJSON
        self.workingDir = workingDir
        self.mcpConfigPath = mcpConfigPath
    }
}

public struct AgentTurnResult {
    public let reply: String
    public let sessionID: String?
    public let numTurns: Int?
    public let durationMs: Int?
    public let denials: [String]
    public let isError: Bool
    public let rawError: String?

    public init(
        reply: String,
        sessionID: String?,
        numTurns: Int? = nil,
        durationMs: Int? = nil,
        denials: [String] = [],
        isError: Bool = false,
        rawError: String? = nil
    ) {
        self.reply = reply
        self.sessionID = sessionID
        self.numTurns = numTurns
        self.durationMs = durationMs
        self.denials = denials
        self.isError = isError
        self.rawError = rawError
    }
}

public protocol AgentTurnRunner {
    func runTurn(prompt: String, sessionID: String?, options: ChatListenOptions) throws -> AgentTurnResult
}

public final class SessionStore {
    public var directoryURL: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/cosmokit/sessions", isDirectory: true)
        }
    }

    public func loadSessionID(for threadID: UUID) -> String? {
        let file = directoryURL.appendingPathComponent("\(threadID.uuidString).json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["sessionId"] as? String, !sessionID.isEmpty else {
            return nil
        }
        return sessionID
    }

    public func saveSessionID(_ sessionID: String, for threadID: UUID) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let file = directoryURL.appendingPathComponent("\(threadID.uuidString).json")
        let payload: [String: Any] = [
            "threadId": threadID.uuidString,
            "sessionId": sessionID,
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    public func clearSessionID(for threadID: UUID) {
        let file = directoryURL.appendingPathComponent("\(threadID.uuidString).json")
        try? FileManager.default.removeItem(at: file)
    }
}

public final class ClaudeTurnRunner: AgentTurnRunner {
    public static var activeProcess: Process?
    private static let lock = NSLock()

    public static func setActiveProcess(_ proc: Process?) {
        lock.lock()
        activeProcess = proc
        lock.unlock()
    }

    public static func terminateActiveProcess() {
        lock.lock()
        defer { lock.unlock() }
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        activeProcess = nil
    }

    public static var defaultExecutableFinder: () -> String? = {
        let fileManager = FileManager.default
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs = envPath.split(separator: ":").map(String.init)
        let home = fileManager.homeDirectoryForCurrentUser.path
        let common = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        for dir in common where !dirs.contains(dir) {
            dirs.append(dir)
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent("claude")
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public var executableFinder: () -> String? = ClaudeTurnRunner.defaultExecutableFinder

    public var processRunner: (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> (stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) = { executable, arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.environment = ProcessInfo.processInfo.environment

        try process.run()
        ClaudeTurnRunner.setActiveProcess(process)
        defer { ClaudeTurnRunner.setActiveProcess(nil) }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrHandle.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2.0)

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
        return (stdoutStr, stderrStr, process.terminationStatus, timedOut)
    }

    public init() {}

    public func buildArguments(prompt: String, sessionID: String?, options: ChatListenOptions, mcpConfigPath: String) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "json",
            "--mcp-config", mcpConfigPath
        ]

        let allowedTools: String
        if options.allowEdits {
            allowedTools = "mcp__cosmokit__*,Read,Grep,Glob,Edit,Write,Bash"
            args += ["--allowedTools", allowedTools, "--permission-mode", "acceptEdits"]
        } else {
            allowedTools = "mcp__cosmokit__*,Read,Grep,Glob"
            args += ["--allowedTools", allowedTools]
        }

        if let model = options.model, !model.isEmpty {
            args += ["--model", model]
        }

        args += [
            "--append-system-prompt",
            "You are answering messages sent by a developer in the CosmoKit Agent window. Be concise and direct. If simulator context or screenshots are provided, inspect them with your tools."
        ]

        if let sessionID, !sessionID.isEmpty {
            args += ["--resume", sessionID]
        }

        return args
    }

    public func runTurn(prompt: String, sessionID: String?, options: ChatListenOptions) throws -> AgentTurnResult {
        guard let executable = executableFinder() else {
            return AgentTurnResult(
                reply: "Could not find 'claude' CLI on PATH. Make sure Claude Code is installed (https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) and available in your PATH.",
                sessionID: sessionID,
                isError: true,
                rawError: "claude not found on PATH"
            )
        }

        guard let mcpConfigPath = options.mcpConfigPath else {
            return AgentTurnResult(
                reply: "Internal error: MCP configuration file is missing.",
                sessionID: sessionID,
                isError: true,
                rawError: "missing mcp config"
            )
        }

        let args = buildArguments(prompt: prompt, sessionID: sessionID, options: options, mcpConfigPath: mcpConfigPath)
        let outcome = try processRunner(executable, args, options.timeout)

        if outcome.timedOut {
            return AgentTurnResult(
                reply: "Claude turn timed out after \(Int(options.timeout)) seconds.",
                sessionID: sessionID,
                isError: true,
                rawError: "turn timed out"
            )
        }

        // Check if resume failed because the session no longer exists
        if outcome.exitCode != 0 && sessionID != nil {
            let combined = outcome.stdout + " " + outcome.stderr
            if isSessionNotFoundError(combined) {
                // Retry once without --resume
                let freshOptions = options
                let freshArgs = buildArguments(prompt: prompt, sessionID: nil, options: freshOptions, mcpConfigPath: mcpConfigPath)
                let freshOutcome = try processRunner(executable, freshArgs, options.timeout)
                if freshOutcome.exitCode == 0, let parsed = parseOutput(freshOutcome.stdout, fallbackSessionID: nil) {
                    let prefixedReply = "Previous session expired or could not be resumed. Started a new session.\n\n\(parsed.reply)"
                    return AgentTurnResult(
                        reply: prefixedReply,
                        sessionID: parsed.sessionID,
                        numTurns: parsed.numTurns,
                        durationMs: parsed.durationMs,
                        denials: parsed.denials,
                        isError: false
                    )
                }
            }
        }

        // Check for login error in stdout/stderr
        let combined = outcome.stdout + " " + outcome.stderr
        if isLoginError(combined) {
            return AgentTurnResult(
                reply: "Claude is not logged in. Run 'claude' once in your terminal to log in, then try again.",
                sessionID: sessionID,
                isError: true,
                rawError: "not logged in"
            )
        }

        // Parse JSON output if present
        if let parsed = parseOutput(outcome.stdout, fallbackSessionID: sessionID) {
            if parsed.isError && isLoginError(parsed.reply) {
                return AgentTurnResult(
                    reply: "Claude is not logged in. Run 'claude' once in your terminal to log in, then try again.",
                    sessionID: parsed.sessionID,
                    isError: true,
                    rawError: "not logged in"
                )
            }
            return parsed
        }

        // Exit was non-zero and no JSON could be parsed
        if outcome.exitCode != 0 {
            let errorText = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = errorText.isEmpty ? "exit status \(outcome.exitCode)" : errorText
            let truncated = display.count > 500 ? String(display.prefix(500)) + "..." : display
            return AgentTurnResult(
                reply: "Claude failed with error: \(truncated)",
                sessionID: sessionID,
                isError: true,
                rawError: display
            )
        }

        // Invalid JSON on stdout
        let stdoutTrimmed = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = stdoutTrimmed.count > 500 ? String(stdoutTrimmed.prefix(500)) + "..." : stdoutTrimmed
        return AgentTurnResult(
            reply: "Claude produced invalid output: \(snippet.isEmpty ? "(empty stdout)" : snippet)",
            sessionID: sessionID,
            isError: true,
            rawError: "invalid JSON on stdout"
        )
    }

    private func isSessionNotFoundError(_ text: String) -> Bool {
        text.contains("No conversation found with session ID") ||
        text.contains("No session found with ID") ||
        (text.contains("session") && text.contains("not found")) ||
        text.contains("Could not resume session")
    }

    private func isLoginError(_ text: String) -> Bool {
        text.contains("Not logged in") ||
        text.contains("Please run /login") ||
        text.contains("run `claude` to log in") ||
        text.contains("Authentication error") ||
        text.contains("auth_error")
    }

    private func parseOutput(_ stdout: String, fallbackSessionID: String?) -> AgentTurnResult? {
        guard let data = stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let isError = json["is_error"] as? Bool ?? false
        let sessionID = (json["session_id"] as? String) ?? fallbackSessionID
        let numTurns = json["num_turns"] as? Int
        let durationMs = (json["duration_ms"] as? NSNumber)?.intValue
        var rawResult = json["result"] as? String ?? ""

        var denials: [String] = []
        if let rawDenials = json["permission_denials"] as? [Any] {
            for item in rawDenials {
                if let str = item as? String {
                    denials.append(str)
                } else if let dict = item as? [String: Any] {
                    if let toolName = dict["tool_name"] as? String ?? dict["tool"] as? String {
                        denials.append(toolName)
                    }
                }
            }
        }

        if !denials.isEmpty {
            rawResult += "\n\n(Tool call was denied: \(denials.joined(separator: ", ")). Run with --allow-edits to permit file modifications.)"
        }

        // Cap message at 20,000 characters
        if rawResult.count > 20_000 {
            let note = "\n\n[truncated: output exceeded 20,000 characters]"
            let maxLen = max(0, 20_000 - note.count)
            rawResult = String(rawResult.prefix(maxLen)) + note
        }

        return AgentTurnResult(
            reply: rawResult,
            sessionID: sessionID,
            numTurns: numTurns,
            durationMs: durationMs,
            denials: denials,
            isError: isError,
            rawError: isError ? rawResult : nil
        )
    }
}

public enum ChatListener {
    public static var activeTempDir: URL?
    private static let cleanupLock = NSLock()
    private static var isCleaningUp = false

    public static func registerCleanup(tempDir: URL) {
        cleanupLock.lock()
        activeTempDir = tempDir
        cleanupLock.unlock()
    }

    public static func cleanupTempDir() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        if let dir = activeTempDir {
            try? FileManager.default.removeItem(at: dir)
            activeTempDir = nil
        }
    }

    public static func setupSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            cleanupAndExit()
        }
        sigintSource.resume()

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            cleanupAndExit()
        }
        sigtermSource.resume()
    }

    public static func cleanupAndExit() {
        cleanupLock.lock()
        if isCleaningUp {
            cleanupLock.unlock()
            return
        }
        isCleaningUp = true
        cleanupLock.unlock()

        ClaudeTurnRunner.terminateActiveProcess()
        cleanupTempDir()
        exit(0)
    }

    public static func createTempMCPConfig(cosmokitPath: String? = nil) throws -> (tempDir: URL, configFile: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cosmokit-chat-listen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let configFile = tempDir.appendingPathComponent("mcp-config.json")

        let binaryPath: String
        if let cosmokitPath {
            binaryPath = cosmokitPath
        } else if let exec = Bundle.main.executablePath, exec.hasSuffix("cosmokit") {
            binaryPath = exec
        } else {
            let arg0 = CommandLine.arguments[0]
            if arg0.hasPrefix("/") {
                binaryPath = arg0
            } else {
                binaryPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(arg0).standardized.path
            }
        }

        let config: [String: Any] = [
            "mcpServers": [
                "cosmokit": [
                    "command": binaryPath,
                    "args": ["mcp"],
                    "env": [
                        "COSMOKIT_CHAT": "off"
                    ]
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile)
        registerCleanup(tempDir: tempDir)
        return (tempDir, configFile)
    }

    public static func formatPrompt(messages: [ChatMessageWire]) -> String {
        messages.map { msg in
            var parts: [String] = []
            if let context = msg.context, !context.isEmpty {
                var ctxLines: [String] = []
                if let udid = context["udid"], !udid.isEmpty { ctxLines.append("Simulator UDID: \(udid)") }
                if let bundleId = context["bundleId"], !bundleId.isEmpty { ctxLines.append("Bundle ID: \(bundleId)") }
                if let path = context["screenshotPath"], !path.isEmpty { ctxLines.append("Screenshot: \(path)") }
                if !ctxLines.isEmpty {
                    parts.append("[Simulator Context]\n" + ctxLines.joined(separator: "\n"))
                }
            }
            parts.append(msg.text)
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }

    public static func verifyAppVersion() throws {
        let controlInfo = try AppControl.readControlInfo()
        if AppControl.isVersion(controlInfo.version, olderThan: "4.9.0") {
            throw CLIError(commandError: CommandError(
                code: .appTooOld,
                message: "CosmoKit version \(controlInfo.version) is too old for chat listen",
                hint: "CosmoKit 4.9.0 or newer is required (found \(controlInfo.version))"
            ))
        }
    }

    public static func start(
        options: ChatListenOptions,
        runner: AgentTurnRunner = ClaudeTurnRunner(),
        chatClient: ChatClient? = nil,
        sessionStore: SessionStore = SessionStore()
    ) throws {
        guard options.agent == "claude" else {
            throw CLIError(commandError: CommandError(
                code: .usage,
                message: "unsupported agent '\(options.agent)'. Currently only 'claude' is supported."
            ))
        }

        setupSignalHandlers()

        var effectiveOptions = options
        var tempDirToRemove: URL?

        if effectiveOptions.mcpConfigPath == nil {
            let (tempDir, configFile) = try createTempMCPConfig()
            effectiveOptions.mcpConfigPath = configFile.path
            tempDirToRemove = tempDir
        }
        defer {
            if let tempDirToRemove {
                try? FileManager.default.removeItem(at: tempDirToRemove)
            }
        }

        let client = chatClient ?? ChatClient(clientName: "claude-listen", workingDir: effectiveOptions.workingDir)

        // Wait for CosmoKit app if not running or too old
        var printedWaitingMessage = false
        var threadID: UUID!

        while threadID == nil {
            do {
                if chatClient == nil || AppControl.controlFileURLOverride != nil {
                    try verifyAppVersion()
                }
                try client.registerIfNeeded()
                if let id = client.currentThreadID {
                    threadID = id
                }
            } catch let error as CLIError where error.commandError.code == .appNotRunning || error.commandError.code == .appTooOld {
                if !printedWaitingMessage {
                    if options.isJSON {
                        emitJSON(["event": "waiting", "message": error.commandError.message])
                    } else {
                        print("Waiting for CosmoKit: \(error.commandError.message)")
                    }
                    printedWaitingMessage = true
                }
                Thread.sleep(forTimeInterval: 5.0)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain {
                    if !printedWaitingMessage {
                        if options.isJSON {
                            emitJSON(["event": "waiting", "message": "CosmoKit is not reachable"])
                        } else {
                            print("Waiting for CosmoKit to become available...")
                        }
                        printedWaitingMessage = true
                    }
                    Thread.sleep(forTimeInterval: 5.0)
                } else {
                    throw error
                }
            }
        }

        // Start heartbeat timer
        let heartbeatQueue = DispatchQueue(label: "com.cosmokit.chat-listen.heartbeat")
        let heartbeatTimer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        heartbeatTimer.schedule(deadline: .now() + 15, repeating: 20.0)
        heartbeatTimer.setEventHandler { [weak client] in
            _ = try? client?.heartbeat()
        }
        heartbeatTimer.resume()
        defer {
            heartbeatTimer.cancel()
        }

        // Resolve session ID
        var currentSessionID: String?
        if options.isNewSession {
            sessionStore.clearSessionID(for: threadID)
            currentSessionID = nil
        } else {
            currentSessionID = sessionStore.loadSessionID(for: threadID)
        }

        // Startup terminal output
        let toolSummary = options.allowEdits ? "simulator + edits allowed" : "simulator + read-only"
        let threadPrefix = String(threadID.uuidString.prefix(8))
        if options.isJSON {
            var startPayload: [String: Any] = [
                "event": "start",
                "threadId": threadID.uuidString,
                "session": currentSessionID == nil ? "new" : "resumed",
                "tools": toolSummary
            ]
            if let sid = currentSessionID { startPayload["sessionId"] = sid }
            emitJSON(startPayload)
        } else {
            let sessionSummary = currentSessionID.map { "session \($0)" } ?? "new session"
            print("cosmokit chat listen: thread \(threadPrefix), \(sessionSummary), tools: \(toolSummary)")
        }

        // Long-poll loop
        while true {
            let messages: [ChatMessageWire]
            do {
                messages = try client.read(wait: 25)
            } catch let error as CLIError where error.commandError.code == .appNotRunning || error.commandError.code == .appTooOld {
                if options.isJSON {
                    emitJSON(["event": "waiting", "message": error.commandError.message])
                } else {
                    print("Waiting for CosmoKit: \(error.commandError.message)")
                }
                Thread.sleep(forTimeInterval: 5.0)
                continue
            } catch {
                Thread.sleep(forTimeInterval: 2.0)
                continue
            }

            guard !messages.isEmpty else { continue }

            // Log received event
            let firstText = messages.first?.text ?? ""
            let preview = firstText.prefix(80).replacingOccurrences(of: "\n", with: " ")
            if options.isJSON {
                emitJSON([
                    "event": "message",
                    "id": messages.first?.id.uuidString ?? "",
                    "from": "human",
                    "count": messages.count,
                    "text": firstText
                ])
            } else {
                print("[received] \(preview)")
            }

            // Build prompt & run turn
            let prompt = formatPrompt(messages: messages)
            let startTime = Date()

            let turnResult: AgentTurnResult
            do {
                turnResult = try runner.runTurn(prompt: prompt, sessionID: currentSessionID, options: effectiveOptions)
            } catch {
                turnResult = AgentTurnResult(
                    reply: "Error executing agent turn: \(error.localizedDescription)",
                    sessionID: currentSessionID,
                    isError: true,
                    rawError: error.localizedDescription
                )
            }

            let elapsedSeconds = Date().timeIntervalSince(startTime)

            // Update session ID if available
            if let newSessionID = turnResult.sessionID, !newSessionID.isEmpty {
                currentSessionID = newSessionID
                sessionStore.saveSessionID(newSessionID, for: threadID)
            }

            // Post reply back to CosmoKit
            _ = try? client.reply(turnResult.reply)

            // Log reply event
            let replyPreview = turnResult.reply.prefix(80).replacingOccurrences(of: "\n", with: " ")
            let turnsCount = turnResult.numTurns ?? 1
            if options.isJSON {
                var replyPayload: [String: Any] = [
                    "event": "reply",
                    "durationSec": Double(round(elapsedSeconds * 10) / 10),
                    "turns": turnsCount,
                    "text": turnResult.reply,
                    "isError": turnResult.isError
                ]
                if let sid = currentSessionID { replyPayload["sessionId"] = sid }
                emitJSON(replyPayload)
            } else {
                let timingStr = String(format: "%.1fs", elapsedSeconds)
                let turnStr = turnsCount == 1 ? "1 turn" : "\(turnsCount) turns"
                print("[replied] in \(timingStr) (\(turnStr)): \(replyPreview)")
            }
        }
    }

    private static func emitJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        if let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }
}
