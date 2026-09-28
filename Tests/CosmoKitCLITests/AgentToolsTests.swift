import XCTest
@testable import CosmoKitCLI

final class AgentToolsTests: XCTestCase {
    func testTapAcceptsRefOrCompleteCoordinatesOnly() throws {
        XCTAssertEqual(try MCPServer.commandInvocation(tool: "ui_tap", arguments: ["ref": 4]).args, ["tap", "4"])
        XCTAssertEqual(try MCPServer.commandInvocation(tool: "ui_tap", arguments: ["x": 10.5, "y": 20]).args, ["tap", "10.5,20.0"])
        XCTAssertThrowsError(try MCPServer.commandInvocation(tool: "ui_tap", arguments: ["x": 1]))
        XCTAssertThrowsError(try MCPServer.commandInvocation(tool: "ui_tap", arguments: ["ref": 1, "x": 1, "y": 2]))
    }

    func testTreeValidatesModeAndMapsOptions() throws {
        let invocation = try MCPServer.commandInvocation(tool: "ui_tree", arguments: ["mode": "debug", "depth": 3, "max": 20, "app": "com.example.app"])
        XCTAssertEqual(invocation.args, ["tree", "--mode", "debug", "--depth", "3", "--max", "20", "--app", "com.example.app"])
        XCTAssertThrowsError(try MCPServer.commandInvocation(tool: "ui_tree", arguments: ["mode": "cheap-screenshot"]))
    }

    func testEveryAgentToolIsAdvertised() throws {
        let response = try XCTUnwrap(MCPServer.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let data = try XCTUnwrap(response.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap((object["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for name in ["agent_start", "agent_stop", "agent_status", "ui_tree", "ui_tap", "ui_press", "ui_swipe", "ui_type", "ui_button", "ui_alert", "ui_screenshot", "ui_find", "ui_wait", "ui_do", "agent_stream", "feedback", "doctor"] {
            XCTAssertNotNil(tools.first { $0["name"] as? String == name })
        }
    }

    func testScreenshotCallReturnsImageContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cosmokit-test.png")
        try Data([137, 80, 78, 71]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        MCPServer.execute = { _, _, _ in CommandOutcome(human: url.path, json: UIScreenshotPayload(path: url.path, width: 1, height: 1, bytes: 4)) }
        defer { MCPServer.execute = { try CLI.perform(command: $0, args: $1, output: $2) } }
        let response = try XCTUnwrap(MCPServer.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_screenshot","arguments":{}}}"#))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let content = try XCTUnwrap(((object["result"] as? [String: Any])?["content"] as? [[String: Any]]))
        XCTAssertTrue(content.contains { $0["type"] as? String == "image" && $0["mimeType"] as? String == "image/png" })
    }

    func testEnsureTargetAppSkipsCallWhenSavedTargetMatches() throws {
        var httpCalls: [String] = []
        let origHttp = Driver.httpForTesting
        defer { Driver.httpForTesting = origHttp }
        Driver.httpForTesting = { method, url, _ in
            httpCalls.append("\(method) \(url.path)")
            return (Data("{\"ok\":true}".utf8), 200)
        }

        let testDevice = "test-device-\(UUID().uuidString)"
        Driver.saveTargetApp("apps.test.app", for: testDevice)

        // When saved target matches requested target, ensureTargetApp must NOT call /app
        try Driver.ensureTargetApp("apps.test.app", device: testDevice)
        XCTAssertEqual(httpCalls, [])

        // When saved target differs, ensureTargetApp calls /app
        try Driver.ensureTargetApp("apps.test.other", device: testDevice)
        XCTAssertTrue(httpCalls.contains { $0.contains("/app") })
        XCTAssertEqual(Driver.targetApp(for: testDevice), "apps.test.other")
    }

    func testSnapshotFallbackWalkWhenSelectorUnavailable() throws {
        var httpCalls: [String] = []
        let origHttp = Driver.httpForTesting
        defer { Driver.httpForTesting = origHttp }
        Driver.httpForTesting = { method, url, _ in
            httpCalls.append("\(method) \(url.path)")
            let fallbackJSON = """
            {"app":"com.example.app","elements":[{"children":[],"enabled":true,"frame":{"height":100,"width":100,"x":0,"y":0},"id":"btn","label":"Click Me","placeholder":"","ref":1,"selected":false,"focused":true,"type":"button"}],"truncated":false}
            """
            return (Data(fallbackJSON.utf8), 200)
        }
        let outcome = try CLI.perform(command: "ui", args: ["tree", "--app", "com.example.app", "--mode", "act"], output: nil)
        XCTAssertTrue(outcome.human.contains("Click Me"))
        XCTAssertTrue(outcome.human.contains("screen:"))
    }
}
