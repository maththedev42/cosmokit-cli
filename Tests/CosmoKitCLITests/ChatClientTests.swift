import XCTest
@testable import CosmoKitCLI

final class ChatClientTests: XCTestCase {
    private var directory: URL!
    private var controlFile: URL!
    private let threadID = UUID()
    private var requests: [String] = []
    private var pollResponses: [Data] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controlFile = directory.appendingPathComponent("agent-control.json")
        let control = ["pid": 123, "port": 54321, "token": "test", "version": "4.8.0"] as [String: Any]
        try JSONSerialization.data(withJSONObject: control).write(to: controlFile)
        AppControl.controlFileURLOverride = controlFile
        AppControl.isPidAliveForTesting = { _ in true }
        AppControl.httpForTesting = { [self] request in
            let path = request.url?.path ?? ""
            requests.append("\(request.httpMethod ?? "GET") \(path)")
            if path == "/v1/chat/agents" {
                return (Data("{\"threadId\":\"\(threadID.uuidString)\"}".utf8), 200)
            }
            if path.hasSuffix("/heartbeat") { return (Data(), 204) }
            if path == "/v1/chat/threads" {
                let value = "[{\"id\":\"\(threadID.uuidString)\",\"agentName\":\"codex — project\",\"clientName\":\"codex\",\"workingDir\":\"/tmp/project\",\"createdAt\":\"2026-09-26T00:00:00Z\",\"lastSeenAt\":\"2026-09-26T00:00:00Z\",\"isOnline\":true,\"unreadCount\":0}]"
                return (Data(value.utf8), 200)
            }
            if path.hasSuffix("/messages") {
                if request.httpMethod == "POST" {
                    let value = "{\"id\":\"\(UUID().uuidString)\",\"threadId\":\"\(threadID.uuidString)\",\"from\":\"agent\",\"text\":\"sent\",\"at\":\"2026-09-26T00:00:00Z\",\"context\":null,\"feedbackSeq\":null}"
                    return (Data(value.utf8), 200)
                }
                if !pollResponses.isEmpty { return (pollResponses.removeFirst(), 200) }
                return (Data("[]".utf8), 200)
            }
            return (Data(), 204)
        }
    }

    override func tearDownWithError() throws {
        AppControl.controlFileURLOverride = nil
        AppControl.isPidAliveForTesting = nil
        AppControl.httpForTesting = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testRegisterReplyAndRead() throws {
        let client = ChatClient()
        try client.registerIfNeeded()
        let reply = try client.reply("human-readable result")
        XCTAssertEqual(reply.threadId, threadID)
        let messageID = UUID()
        let message = "{\"id\":\"\(messageID.uuidString)\",\"threadId\":\"\(threadID.uuidString)\",\"from\":\"human\",\"text\":\"Inspect this\",\"at\":\"2026-09-26T00:00:00Z\",\"context\":{\"screenshotPath\":\"/tmp/chat.png\"},\"feedbackSeq\":null}"
        pollResponses = [Data("[\(message)]".utf8), Data("[]".utf8)]
        XCTAssertEqual(try client.read(wait: 0).count, 1)
        XCTAssertEqual(try client.read(wait: 0).count, 0)
        XCTAssertTrue(requests.contains { $0.hasPrefix("POST /v1/chat/agents") })
        XCTAssertTrue(requests.contains { $0.hasPrefix("POST /v1/chat/threads/\(threadID.uuidString)/messages") })
    }

    func testAppNotRunningWhenControlFileIsMissing() {
        try? FileManager.default.removeItem(at: controlFile)
        XCTAssertThrowsError(try ChatClient().registerIfNeeded()) { error in
            XCTAssertEqual((error as? CLIError)?.commandError.code, .appNotRunning)
        }
    }

    func testFeedbackMirrorDeduplicatesSequence() throws {
        let client = ChatClient()
        try client.registerIfNeeded()
        let element = FeedbackElementPayload(ref: 1, type: "button", label: "Send")
        let record = FeedbackRecordPayload(seq: 7, at: "2026-09-26T00:00:00Z", x: 1, y: 2,
                                           element: element, text: "Please check", frame: "frame",
                                           udid: "UDID")
        client.mirror(record)
        client.mirror(record)
        XCTAssertEqual(requests.filter { $0.contains("feedback-mirror") }.count, 1)
    }

    func testReadReturnsEmptyOnTimeout() throws {
        let client = ChatClient()
        try client.registerIfNeeded()

        var requestedTimeout: TimeInterval?
        AppControl.httpForTesting = { request in
            if request.url?.path.contains("/messages") == true {
                requestedTimeout = request.timeoutInterval
                throw URLError(.timedOut)
            }
            return (Data(), 200)
        }

        let result = try client.read(wait: 15)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(requestedTimeout, 35) // 15 + 20 margin
    }

    func testReadRethrowsRealConnectionError() throws {
        let client = ChatClient()
        try client.registerIfNeeded()

        AppControl.httpForTesting = { request in
            if request.url?.path.contains("/messages") == true {
                throw URLError(.cannotConnectToHost)
            }
            return (Data(), 200)
        }

        XCTAssertThrowsError(try client.read(wait: 5)) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }
}
