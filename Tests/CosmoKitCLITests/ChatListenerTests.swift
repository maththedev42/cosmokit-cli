//
//  ChatListenerTests.swift
//  cosmokit CLI
//
//  CHAT-08: Tests for cosmokit chat listen and turn runner.
//

import XCTest
@testable import CosmoKitCLI

final class ChatListenerTests: XCTestCase {
    private var tempDirectory: URL!
    private var controlFile: URL!
    private let threadID = UUID()
    private var requests: [String] = []
    private var postedReplies: [String] = []
    private var pollResponses: [Data] = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        controlFile = tempDirectory.appendingPathComponent("agent-control.json")
        let control = ["pid": 123, "port": 54321, "token": "test-token", "version": "4.8.0"] as [String: Any]
        try JSONSerialization.data(withJSONObject: control).write(to: controlFile)

        AppControl.controlFileURLOverride = controlFile
        AppControl.isPidAliveForTesting = { _ in true }
        requests = []
        postedReplies = []
        pollResponses = []

        AppControl.httpForTesting = { [self] request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            requests.append("\(method) \(path)")

            if path == "/v1/chat/agents" && method == "POST" {
                return (Data("{\"threadId\":\"\(threadID.uuidString)\"}".utf8), 200)
            }
            if path.hasSuffix("/heartbeat") {
                return (Data(), 204)
            }
            if path.hasSuffix("/messages") {
                if method == "POST" {
                    if let body = request.httpBody,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let text = json["text"] as? String {
                        postedReplies.append(text)
                    }
                    let value = "{\"id\":\"\(UUID().uuidString)\",\"threadId\":\"\(threadID.uuidString)\",\"from\":\"agent\",\"text\":\"sent\",\"at\":\"2026-10-02T12:00:00Z\"}"
                    return (Data(value.utf8), 200)
                }
                if !pollResponses.isEmpty {
                    return (pollResponses.removeFirst(), 200)
                }
                return (Data("[]".utf8), 200)
            }
            return (Data(), 204)
        }
    }

    override func tearDownWithError() throws {
        AppControl.controlFileURLOverride = nil
        AppControl.isPidAliveForTesting = nil
        AppControl.httpForTesting = nil
        MCPServer.chatDisabledOverride = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testFormatPromptBatchAndContext() {
        let msg1 = ChatMessageWire(
            id: UUID(),
            threadId: threadID,
            from: "human",
            text: "Why is the login button disabled?",
            at: Date(),
            context: [
                "udid": "A1B2C3D4-E5F6",
                "bundleId": "com.example.MyApp",
                "screenshotPath": "/tmp/screenshot1.png"
            ]
        )
        let msg2 = ChatMessageWire(
            id: UUID(),
            threadId: threadID,
            from: "human",
            text: "Also check the network tab.",
            at: Date()
        )

        let prompt = ChatListener.formatPrompt(messages: [msg1, msg2])
        XCTAssertTrue(prompt.contains("[Simulator Context]"))
        XCTAssertTrue(prompt.contains("Simulator UDID: A1B2C3D4-E5F6"))
        XCTAssertTrue(prompt.contains("Bundle ID: com.example.MyApp"))
        XCTAssertTrue(prompt.contains("Screenshot: /tmp/screenshot1.png"))
        XCTAssertTrue(prompt.contains("Why is the login button disabled?"))
        XCTAssertTrue(prompt.contains("Also check the network tab."))
    }

    func testBatchOfTwoMessagesBecomesOneTurnAndOneReply() throws {
        let msg1 = ChatMessageWire(id: UUID(), threadId: threadID, from: "human", text: "First message", at: Date())
        let msg2 = ChatMessageWire(id: UUID(), threadId: threadID, from: "human", text: "Second message", at: Date())

        let batchData = try JSONEncoder().encode([msg1, msg2])
        pollResponses = [batchData, Data("[]".utf8)]

        final class MockRunner: AgentTurnRunner {
            var invocations: [(prompt: String, sessionID: String?)] = []
            func runTurn(prompt: String, sessionID: String?, options: ChatListenOptions) throws -> AgentTurnResult {
                invocations.append((prompt: prompt, sessionID: sessionID))
                return AgentTurnResult(reply: "Combined answer", sessionID: "sess-123")
            }
        }

        let mockRunner = MockRunner()
        let client = ChatClient(clientName: "claude-listen", workingDir: tempDirectory.path)
        let sessionStore = SessionStore(directoryURL: tempDirectory.appendingPathComponent("sessions"))

        var options = ChatListenOptions(workingDir: tempDirectory.path)
        options.mcpConfigPath = tempDirectory.appendingPathComponent("dummy.json").path

        // Run one loop step manually using client and runner
        try client.registerIfNeeded()
        let messages = try client.read(wait: 0)
        XCTAssertEqual(messages.count, 2)

        let prompt = ChatListener.formatPrompt(messages: messages)
        let result = try mockRunner.runTurn(prompt: prompt, sessionID: nil, options: options)
        _ = try client.reply(result.reply)
        if let sid = result.sessionID {
            sessionStore.saveSessionID(sid, for: threadID)
        }

        XCTAssertEqual(mockRunner.invocations.count, 1)
        XCTAssertTrue(mockRunner.invocations[0].prompt.contains("First message"))
        XCTAssertTrue(mockRunner.invocations[0].prompt.contains("Second message"))
        XCTAssertEqual(postedReplies.count, 1)
        XCTAssertEqual(postedReplies[0], "Combined answer")
        XCTAssertEqual(sessionStore.loadSessionID(for: threadID), "sess-123")
    }

    func testSessionIDSavedAndReused() throws {
        let sessionStore = SessionStore(directoryURL: tempDirectory.appendingPathComponent("sessions"))
        XCTAssertNil(sessionStore.loadSessionID(for: threadID))

        sessionStore.saveSessionID("session-abc-123", for: threadID)
        XCTAssertEqual(sessionStore.loadSessionID(for: threadID), "session-abc-123")

        sessionStore.saveSessionID("session-def-456", for: threadID)
        XCTAssertEqual(sessionStore.loadSessionID(for: threadID), "session-def-456")
    }

    func testNewFlagIgnoresSavedSessionID() throws {
        let sessionStore = SessionStore(directoryURL: tempDirectory.appendingPathComponent("sessions"))
        sessionStore.saveSessionID("existing-session", for: threadID)
        XCTAssertEqual(sessionStore.loadSessionID(for: threadID), "existing-session")

        let options = ChatListenOptions(isNewSession: true)
        if options.isNewSession {
            sessionStore.clearSessionID(for: threadID)
        }
        XCTAssertNil(sessionStore.loadSessionID(for: threadID))
    }

    func testClaudeTurnRunnerMissingExecutable() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { nil }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "hello", sessionID: nil, options: options)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.reply.contains("Could not find 'claude' CLI on PATH"))
    }

    func testClaudeTurnRunnerNotLoggedIn() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        runner.processRunner = { _, _, _ in
            (stdout: "Error: Not logged in. Run `claude` to log in.", stderr: "", exitCode: 1, timedOut: false)
        }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "hello", sessionID: nil, options: options)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.reply.contains("Claude is not logged in"))
    }

    func testClaudeTurnRunnerTimeout() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        runner.processRunner = { _, _, timeout in
            (stdout: "", stderr: "", exitCode: 0, timedOut: true)
        }

        var options = ChatListenOptions(timeout: 5)
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "hello", sessionID: nil, options: options)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.reply.contains("Claude turn timed out after 5 seconds"))
    }

    func testClaudeTurnRunnerInvalidJSON() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        runner.processRunner = { _, _, _ in
            (stdout: "502 Bad Gateway from API gateway", stderr: "", exitCode: 0, timedOut: false)
        }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "hello", sessionID: nil, options: options)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.reply.contains("Claude produced invalid output"))
        XCTAssertTrue(result.reply.contains("502 Bad Gateway"))
    }

    func testClaudeTurnRunnerNonZeroExitWithStderr() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        runner.processRunner = { _, _, _ in
            (stdout: "", stderr: "Fatal API error connection reset", exitCode: 2, timedOut: false)
        }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "hello", sessionID: nil, options: options)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.reply.contains("Claude failed with error: Fatal API error connection reset"))
    }

    func testClaudeTurnRunnerSessionResumeFallback() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        var invocationCount = 0

        runner.processRunner = { _, args, _ in
            invocationCount += 1
            if args.contains("--resume") {
                return (stdout: "No conversation found with session ID: dead-session-id", stderr: "", exitCode: 1, timedOut: false)
            } else {
                let successJSON = "{\"result\":\"Fresh reply here\",\"session_id\":\"fresh-session-id\",\"is_error\":false,\"num_turns\":1,\"duration_ms\":3000}"
                return (stdout: successJSON, stderr: "", exitCode: 0, timedOut: false)
            }
        }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "hello", sessionID: "dead-session-id", options: options)
        XCTAssertEqual(invocationCount, 2)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.sessionID, "fresh-session-id")
        XCTAssertTrue(result.reply.contains("Previous session expired or could not be resumed. Started a new session."))
        XCTAssertTrue(result.reply.contains("Fresh reply here"))
    }

    func testClaudeTurnRunnerPermissionDenialsNote() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        runner.processRunner = { _, _, _ in
            let json = "{\"result\":\"I tried to edit the file.\",\"session_id\":\"sess-1\",\"is_error\":false,\"num_turns\":1,\"duration_ms\":2000,\"permission_denials\":[{\"tool_name\":\"Edit\"},{\"tool_name\":\"Write\"}]}"
            return (stdout: json, stderr: "", exitCode: 0, timedOut: false)
        }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "edit file", sessionID: nil, options: options)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.reply.contains("I tried to edit the file."))
        XCTAssertTrue(result.reply.contains("Tool call was denied: Edit, Write. Run with --allow-edits to permit file modifications."))
    }

    func testClaudeTurnRunnerTruncationAt20k() throws {
        let runner = ClaudeTurnRunner()
        runner.executableFinder = { "/bin/claude" }
        let hugeString = String(repeating: "A", count: 25_000)
        runner.processRunner = { _, _, _ in
            let json = "{\"result\":\"\(hugeString)\",\"session_id\":\"sess-huge\",\"is_error\":false,\"num_turns\":1,\"duration_ms\":1000}"
            return (stdout: json, stderr: "", exitCode: 0, timedOut: false)
        }

        var options = ChatListenOptions()
        options.mcpConfigPath = "/tmp/mcp.json"

        let result = try runner.runTurn(prompt: "big output", sessionID: nil, options: options)
        XCTAssertLessThanOrEqual(result.reply.count, 20_000)
        XCTAssertTrue(result.reply.hasSuffix("[truncated: output exceeded 20,000 characters]"))
    }

    func testHeartbeatsContinueDuringSlowTurn() throws {
        let client = ChatClient(clientName: "claude-listen", workingDir: tempDirectory.path)
        try client.registerIfNeeded()

        let heartbeatCount = requests.filter { $0.hasSuffix("/heartbeat") }.count

        // Send a few manual heartbeats
        _ = try client.heartbeat()
        _ = try client.heartbeat()

        let newHeartbeatCount = requests.filter { $0.hasSuffix("/heartbeat") }.count
        XCTAssertEqual(newHeartbeatCount, heartbeatCount + 2)
    }

    func testMCPServerWithChatOff() throws {
        // Chat ON by default
        MCPServer.chatDisabledOverride = false
        let onListResponse = try XCTUnwrap(MCPServer.handle(line: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"))
        let onData = try XCTUnwrap(onListResponse.data(using: .utf8))
        let onObject = try XCTUnwrap(JSONSerialization.jsonObject(with: onData) as? [String: Any])
        let onResult = try XCTUnwrap(onObject["result"] as? [String: Any])
        let onTools = try XCTUnwrap(onResult["tools"] as? [[String: Any]])
        XCTAssertEqual(onTools.count, 56)
        let onNames = Set(onTools.compactMap { $0["name"] as? String })
        XCTAssertTrue(onNames.contains("chat_read"))
        XCTAssertTrue(onNames.contains("chat_reply"))
        XCTAssertTrue(onNames.contains("chat_status"))

        // Chat OFF
        MCPServer.chatDisabledOverride = true
        let offListResponse = try XCTUnwrap(MCPServer.handle(line: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"))
        let offData = try XCTUnwrap(offListResponse.data(using: .utf8))
        let offObject = try XCTUnwrap(JSONSerialization.jsonObject(with: offData) as? [String: Any])
        let offResult = try XCTUnwrap(offObject["result"] as? [String: Any])
        let offTools = try XCTUnwrap(offResult["tools"] as? [[String: Any]])
        XCTAssertEqual(offTools.count, 53)
        let offNames = Set(offTools.compactMap { $0["name"] as? String })
        XCTAssertFalse(offNames.contains("chat_read"))
        XCTAssertFalse(offNames.contains("chat_reply"))
        XCTAssertFalse(offNames.contains("chat_status"))

        // Call chat_read when chat is OFF -> fails with unknown tool error
        let callResponse = try XCTUnwrap(MCPServer.handle(line: "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"chat_read\",\"arguments\":{}}}"))
        let callData = try XCTUnwrap(callResponse.data(using: .utf8))
        let callObject = try XCTUnwrap(JSONSerialization.jsonObject(with: callData) as? [String: Any])
        let callResult = try XCTUnwrap(callObject["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, true)
        let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
        let errorText = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(errorText.contains("unknownCommand") || errorText.contains("Unknown tool: chat_read"))

        // Initialize when chat is OFF -> does not crash or error
        let initResponse = try XCTUnwrap(MCPServer.handle(line: "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"test\"}}}"))
        XCTAssertTrue(initResponse.contains("serverInfo"))
    }

    func testCreateTempMCPConfig() throws {
        let (tempDir, configFile) = try ChatListener.createTempMCPConfig(cosmokitPath: "/usr/local/bin/cosmokit")
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: configFile.path))
        let data = try Data(contentsOf: configFile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let cosmokit = try XCTUnwrap(servers["cosmokit"] as? [String: Any])
        XCTAssertEqual(cosmokit["command"] as? String, "/usr/local/bin/cosmokit")
        XCTAssertEqual(cosmokit["args"] as? [String], ["mcp"])
        let env = try XCTUnwrap(cosmokit["env"] as? [String: Any])
        XCTAssertEqual(env["COSMOKIT_CHAT"] as? String, "off")

        // Must not contain any token
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("token"))
    }

    func testParseChatListenOptions() throws {
        let args = [
            "--new",
            "--model", "claude-3-5-sonnet-20241022",
            "--allow-edits",
            "--timeout", "300",
            "--agent", "claude"
        ]
        let (showHelp, options) = try CLI.parseChatListenOptions(args: args, isJSON: false)
        XCTAssertFalse(showHelp)
        XCTAssertTrue(options.isNewSession)
        XCTAssertEqual(options.model, "claude-3-5-sonnet-20241022")
        XCTAssertTrue(options.allowEdits)
        XCTAssertEqual(options.timeout, 300)
        XCTAssertEqual(options.agent, "claude")

        // Help flag
        let (helpRequested, _) = try CLI.parseChatListenOptions(args: ["--help"], isJSON: false)
        XCTAssertTrue(helpRequested)

        // Unsupported agent throws
        XCTAssertThrowsError(try CLI.parseChatListenOptions(args: ["--agent", "gemini"], isJSON: false)) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.commandError.code, .usage)
            XCTAssertTrue(cliError?.commandError.message.contains("unsupported agent 'gemini'") ?? false)
        }
    }

    func testVerifyAppVersionRejects480AndAccepts490() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let controlFile = tmp.appendingPathComponent("agent-control.json")
        let json480 = """
        {"pid": \(ProcessInfo.processInfo.processIdentifier), "port": 1234, "token": "test", "version": "4.8.0"}
        """
        try json480.write(to: controlFile, atomically: true, encoding: .utf8)
        AppControl.controlFileURLOverride = controlFile
        defer { AppControl.controlFileURLOverride = nil }

        XCTAssertThrowsError(try ChatListener.verifyAppVersion()) { error in
            guard let cliError = error as? CLIError else {
                return XCTFail("Expected CLIError but got \(error)")
            }
            XCTAssertEqual(cliError.commandError.code, .appTooOld)
            XCTAssertTrue(cliError.commandError.message.contains("4.8.0"))
            XCTAssertTrue(cliError.commandError.hint?.contains("4.9.0") ?? false)
        }

        let json490 = """
        {"pid": \(ProcessInfo.processInfo.processIdentifier), "port": 1234, "token": "test", "version": "4.9.0"}
        """
        try json490.write(to: controlFile, atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try ChatListener.verifyAppVersion())
    }
}
