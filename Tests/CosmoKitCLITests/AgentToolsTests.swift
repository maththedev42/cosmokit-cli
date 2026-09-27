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
}
