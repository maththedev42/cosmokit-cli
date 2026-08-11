import XCTest
@testable import CosmoKitCLI

final class MCPServerTests: XCTestCase {
    private let toolNames: Set<String> = [
        "list_simulators", "boot_simulator", "shutdown_simulator", "capture_screenshot",
        "record_video", "set_location", "open_url", "erase_simulator"
    ]

    override func tearDown() {
        MCPServer.execute = { try CLI.perform(command: $0, args: $1, output: $2) }
        super.tearDown()
    }

    func testBootCallMapsDeviceArgument() throws {
        var received: (String, [String], String?)?
        MCPServer.execute = { command, args, output in
            received = (command, args, output)
            return CommandOutcome(human: "Booted", json: BootPayload(udid: "U", name: "iPhone 16", alreadyBooted: false))
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"boot_simulator","arguments":{"device":"iPhone 16"}}}"#)
        XCTAssertEqual(received?.0, "boot")
        XCTAssertEqual(received?.1, ["iPhone 16"])
    }

    func testBootCallWithoutArgumentsUsesEmptyArgs() throws {
        var received: [String] = ["unexpected"]
        MCPServer.execute = { _, args, _ in
            received = args
            return CommandOutcome(human: "Booted", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"boot_simulator"}}"#)
        XCTAssertEqual(received, [])
    }

    func testLocationCallCoercesNumbersAndStrings() throws {
        var calls: [[String]] = []
        MCPServer.execute = { _, args, _ in
            calls.append(args)
            return CommandOutcome(human: "Set", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_location","arguments":{"latitude":-22.9068,"longitude":-43.1729}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_location","arguments":{"latitude":"-22.9068","longitude":"-43.1729"}}}"#)
        XCTAssertEqual(calls, [["-22.9068", "-43.1729"], ["-22.9068", "-43.1729"]])
    }

    func testLocationMissingLongitudeIsUsage() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_location","arguments":{"latitude":1}}}"#)
        let text = try toolText(response)
        let failure = try jsonObject(text)
        XCTAssertEqual((failure["error"] as? [String: Any])?["code"] as? String, "usage")
        XCTAssertTrue(((failure["error"] as? [String: Any])?["message"] as? String)?.contains("longitude") == true)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testRecordCallFormatsIntegerDurationWithoutDecimal() throws {
        var received: [String] = []
        MCPServer.execute = { _, args, _ in
            received = args
            return CommandOutcome(human: "Recorded", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_video","arguments":{"duration":5}}}"#)
        XCTAssertEqual(received, ["--duration", "5"])
    }

    func testRecordCallRequiresDuration() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"record_video","arguments":{}}}"#)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(try toolErrorCode(response), "usage")
    }

    func testCaptureCallPassesOutputAndNoDeviceArgs() throws {
        var received: (args: [String], output: String?)?
        MCPServer.execute = { _, args, output in
            received = (args, output)
            return CommandOutcome(human: "capture", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_screenshot","arguments":{"output":"./shots"}}}"#)
        XCTAssertEqual(received?.args, [])
        XCTAssertEqual(received?.output, "./shots")
    }

    func testOpenCallOrdersURLBeforeDevice() throws {
        var received: [String] = []
        MCPServer.execute = { _, args, _ in
            received = args
            return CommandOutcome(human: "opened", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"open_url","arguments":{"url":"myapp://item/42","device":"iPhone 16"}}}"#)
        XCTAssertEqual(received, ["myapp://item/42", "iPhone 16"])
    }

    func testSuccessfulCallReturnsSuccessEnvelopeText() throws {
        MCPServer.execute = { _, _, _ in
            CommandOutcome(human: "Booted", json: BootPayload(udid: "U", name: "iPhone", alreadyBooted: false))
        }
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"boot_simulator"}}"#)
        XCTAssertNil(response["isError"])
        let text = try toolText(response)
        XCTAssertEqual(try jsonObject(text)["ok"] as? Bool, true)
    }

    func testExecutorFailureIsToolErrorWithFailureEnvelope() throws {
        MCPServer.execute = { _, _, _ in
            throw CLIError(commandError: CommandError(code: .deviceNotFound, message: "not found"))
        }
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"boot_simulator","arguments":{"device":"ignored"}}}"#)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(try toolErrorCode(response), "deviceNotFound")
        XCTAssertEqual(try jsonObject(try toolText(response))["ok"] as? Bool, false)
    }

    func testCallWithoutNameIsJSONRPCInvalidParams() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(errorCode(response), -32602)
    }

    func testUnknownToolIsToolError() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(try toolErrorCode(response), "unknownCommand")
    }

    func testUnexpectedArgumentIsIgnored() throws {
        var called = false
        MCPServer.execute = { _, args, _ in
            called = args.isEmpty
            return CommandOutcome(human: "listed", json: EmptyPayload())
        }
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_simulators","arguments":{"extra":"ignored"}}}"#)
        XCTAssertTrue(called)
        XCTAssertNil(response["isError"])
    }

    func testInitializeNegotiatesCurrentVersionAndServerInfo() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(protocolVersion(response), "2025-06-18")
        XCTAssertEqual(serverName(response), "cosmokit")
    }

    func testInitializeEchoesOlderSupportedVersion() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        XCTAssertEqual(protocolVersion(response), "2024-11-05")
    }

    func testInitializeFallsBackForUnknownVersion() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(protocolVersion(response), "2025-06-18")
    }

    func testInitializeAdvertisesToolsCapability() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        let result = response["result"] as! [String: Any]
        let capabilities = result["capabilities"] as! [String: Any]
        XCTAssertNotNil(capabilities["tools"] as? [String: Any])
    }

    func testNotificationsReceiveNoResponse() {
        XCTAssertNil(MCPServer.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(MCPServer.handle(line: #"{"jsonrpc":"2.0","method":"anything"}"#))
    }

    func testToolsListAdvertisesEightToolsAndSchemas() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let result = response["result"] as! [String: Any]
        let tools = result["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 8)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), toolNames)
        for tool in tools {
            let schema = tool["inputSchema"] as! [String: Any]
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"] as? [String: Any])
        }
        let record = try tool(named: "record_video", in: tools)
        XCTAssertEqual(record["required"] as? [String], ["duration"])
        let capture = try tool(named: "capture_screenshot", in: tools)
        XCTAssertEqual(capture["required"] as? [String], [])
        let location = try tool(named: "set_location", in: tools)
        XCTAssertEqual(Set(location["required"] as? [String] ?? []), ["latitude", "longitude"])
    }

    func testUnknownMethodEchoesIdAndErrorCode() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":"abc","method":"nope"}"#)
        XCTAssertEqual(response["id"] as? String, "abc")
        XCTAssertEqual(errorCode(response), -32601)
    }

    func testMalformedAndInvalidRequests() throws {
        let parse = try object(for: "not json")
        XCTAssertTrue(parse["id"] is NSNull)
        XCTAssertEqual(errorCode(parse), -32700)
        XCTAssertEqual(errorCode(try object(for: "[]")), -32600)
        XCTAssertEqual(errorCode(try object(for: #"{"jsonrpc":"2.0","id":1}"#)), -32600)
    }

    func testEveryResponseIsJSONRPC() throws {
        for line in [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"unknown"}"#,
            "not json"
        ] {
            let response = try object(for: line)
            XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        }
    }

    private func object(for line: String) throws -> [String: Any] {
        guard let response = MCPServer.handle(line: line),
              let data = response.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MCPServerTests", code: 1)
        }
        return object
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MCPServerTests", code: 3)
        }
        return object
    }

    private func toolText(_ response: [String: Any]) throws -> String {
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw NSError(domain: "MCPServerTests", code: 4)
        }
        return text
    }

    private func toolErrorCode(_ response: [String: Any]) throws -> String? {
        try (jsonObject(toolText(response))["error"] as? [String: Any])?["code"] as? String
    }

    private func protocolVersion(_ response: [String: Any]) -> String? {
        (response["result"] as? [String: Any])?["protocolVersion"] as? String
    }

    private func serverName(_ response: [String: Any]) -> String? {
        ((response["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String
    }

    private func errorCode(_ response: [String: Any]) -> Int? {
        (response["error"] as? [String: Any])?["code"] as? Int
    }

    private func tool(named name: String, in tools: [[String: Any]]) throws -> [String: Any] {
        guard let tool = tools.first(where: { $0["name"] as? String == name }),
              let schema = tool["inputSchema"] as? [String: Any] else {
            throw NSError(domain: "MCPServerTests", code: 2)
        }
        return schema
    }
}
