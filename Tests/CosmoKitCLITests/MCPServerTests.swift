import XCTest
import SystemConfiguration
@testable import CosmoKitCLI

final class MCPServerTests: XCTestCase {
    private let toolNames: Set<String> = [
        "list_simulators", "boot_simulator", "shutdown_simulator", "capture_screenshot",
        "record_video", "set_location", "open_url", "erase_simulator", "list_apps",
        "install_app", "uninstall_app", "launch_app", "terminate_app", "app_container",
        "set_appearance", "set_status_bar", "clear_status_bar", "set_permission",
        "set_biometric_enrollment", "match_biometric", "install_certificate", "reset_keychain"
        ,"send_push", "list_location_scenarios", "run_location_scenario", "clear_location",
        "add_media", "get_pasteboard", "set_pasteboard", "read_defaults", "write_default",
        "delete_default", "get_logs", "list_runtimes", "proxy_status"
    ]
    private let orderedToolNames = [
        "list_simulators", "list_runtimes",
        "boot_simulator", "shutdown_simulator", "erase_simulator",
        "list_apps", "install_app", "uninstall_app", "launch_app", "terminate_app", "app_container",
        "capture_screenshot", "record_video",
        "set_appearance", "set_status_bar", "clear_status_bar", "set_permission", "set_biometric_enrollment", "match_biometric", "install_certificate", "reset_keychain",
        "open_url", "send_push", "add_media", "get_pasteboard", "set_pasteboard",
        "set_location", "list_location_scenarios", "run_location_scenario", "clear_location",
        "read_defaults", "write_default", "delete_default", "get_logs", "proxy_status"
    ]

    override func tearDown() {
        MCPServer.execute = { try CLI.perform(command: $0, args: $1, output: $2) }
        CLI.runSimctlForTesting = { try Simctl.run($0) }
        CLI.runSimctlTimedForTesting = { try Simctl.run($0, timeout: $1) }
        CLI.proxySourceForTesting = { SCDynamicStoreCopyProxies(nil) as? [String: Any] }
        CLI.resolveDeviceForTesting = { try Simctl.resolveDevice($0) }
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

    func testListAppsMapsWithoutArguments() throws {
        var received: (String, [String])?
        MCPServer.execute = { command, args, _ in
            received = (command, args)
            return CommandOutcome(human: "", json: AppsPayload(udid: "U", name: "iPhone", apps: []))
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#)
        XCTAssertEqual(received?.0, "apps")
        XCTAssertEqual(received?.1, [])
    }

    func testInstallAndUninstallMapArguments() throws {
        var calls: [(String, [String])] = []
        MCPServer.execute = { command, args, _ in
            calls.append((command, args))
            return CommandOutcome(human: "", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"install_app","arguments":{"path":"/tmp/My.app"}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"uninstall_app","arguments":{"bundle_id":"com.example.app"}}}"#)
        XCTAssertEqual(calls.map { $0.0 }, ["install", "uninstall"])
        XCTAssertEqual(calls.map { $0.1 }, [["/tmp/My.app"], ["com.example.app"]])
    }

    func testLaunchMissingBundleIDIsUsage() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"launch_app","arguments":{}}}"#)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue((try toolErrorMessage(response)).contains("bundle_id"))
    }

    func testAppContainerMapsKindAndDefaultsToApp() throws {
        var calls: [[String]] = []
        MCPServer.execute = { _, args, _ in
            calls.append(args)
            return CommandOutcome(human: "", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"app_container","arguments":{"bundle_id":"x","kind":"data"}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"app_container","arguments":{"bundle_id":"x"}}}"#)
        XCTAssertEqual(calls, [["x", "data"], ["x", "app"]])
    }

    func testAppContainerRejectsInvalidKind() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"app_container","arguments":{"bundle_id":"x","kind":"bogus"}}}"#)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(try toolErrorCode(response), "usage")
    }

    func testAppearanceMapsAndReadsWithoutArguments() throws {
        var calls: [[String]] = []
        MCPServer.execute = { _, args, _ in calls.append(args); return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_appearance","arguments":{"appearance":"dark"}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_appearance","arguments":{}}}"#)
        XCTAssertEqual(calls, [["dark"], []])
    }

    func testAppearanceRejectsUnknownValue() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_appearance","arguments":{"appearance":"sepia"}}}"#)
        XCTAssertEqual(try toolErrorCode(response), "usage")
        XCTAssertTrue((try toolErrorMessage(response)).contains("light"))
    }

    func testStatusBarMapsIntegerAndRejectsEmptyOrOutOfRange() throws {
        var received: [String] = []
        MCPServer.execute = { _, args, _ in received = args; return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_status_bar","arguments":{"time":"9:41","battery_level":100}}}"#)
        XCTAssertEqual(received, ["--time", "9:41", "--batteryLevel", "100"])
        let empty = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_status_bar","arguments":{}}}"#)
        XCTAssertEqual(try toolErrorCode(empty), "usage")
        let high = try object(for: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_status_bar","arguments":{"battery_level":150}}}"#)
        XCTAssertEqual(try toolErrorCode(high), "usage")
    }

    func testPermissionValidation() throws {
        let missing = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_permission","arguments":{"action":"grant","service":"photos"}}}"#)
        XCTAssertEqual(try toolErrorCode(missing), "usage")
        var received: [String] = []
        MCPServer.execute = { _, args, _ in received = args; return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_permission","arguments":{"action":"reset","service":"all"}}}"#)
        XCTAssertEqual(received, ["reset", "all"])
        let invalid = try object(for: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_permission","arguments":{"action":"reset","service":"unknown"}}}"#)
        XCTAssertEqual(try toolErrorCode(invalid), "usage")
        XCTAssertTrue((try toolErrorMessage(invalid)).contains("photos"))
    }

    func testBiometricEnrollmentPostsStateThenChange() throws {
        var calls: [[String]] = []
        CLI.runSimctlForTesting = { args in calls.append(args); return "" }
        CLI.resolveDeviceForTesting = { _ in Device(udid: "U", name: "Test Device", state: "Booted", isAvailable: true) }
        _ = try CLI.perform(command: "biometric-enroll", args: ["on"], output: nil)
        XCTAssertEqual(calls, [
            ["spawn", "U", "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", "1"],
            ["spawn", "U", "notifyutil", "-p", "com.apple.BiometricKit.enrollmentChanged"]
        ])
    }

    func testBiometricMatchDefaultsToMatch() throws {
        var received: [String] = []
        MCPServer.execute = { _, args, _ in received = args; return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"match_biometric","arguments":{}}}"#)
        XCTAssertEqual(received, ["match"])
    }

    func testSendPushPreservesValidatedJSONObject() throws {
        var received: [String] = []
        MCPServer.execute = { _, args, _ in received = args; return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_push","arguments":{"payload":{"aps":{"alert":"Hello"}},"bundle_id":"com.example.app"}}}"#)
        XCTAssertEqual(received[0], "com.example.app")
        XCTAssertEqual(received[1], "--payload")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(received[2].utf8)) as? [String: Any])
        XCTAssertNotNil(payload["aps"])
    }

    func testPushValidationFailuresAndTargetBundle() throws {
        let missingAPS = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_push","arguments":{"payload":{},"bundle_id":"x"}}}"#)
        XCTAssertEqual(try toolErrorCode(missingAPS), "usage")
        let array = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_push","arguments":{"payload":[1,2],"bundle_id":"x"}}}"#)
        XCTAssertEqual(try toolErrorCode(array), "usage")
        XCTAssertTrue(try toolErrorMessage(array).contains("JSON object at the top level"))
        let malformed = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_push","arguments":{"payload":"{\"aps\":" ,"bundle_id":"x"}}}"#)
        XCTAssertTrue(try toolErrorMessage(malformed).contains("payload is not valid JSON:"))
        XCTAssertFalse(try toolErrorMessage(malformed).contains("JSON object at the top level"))
        let target = try object(for: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_push","arguments":{"payload":{"aps":{},"Simulator Target Bundle":"com.target"}}}}"#)
        XCTAssertNil(target["error"])
    }

    func testSharedPushValidatorDistinguishesJSONShapes() throws {
        XCTAssertThrowsError(try CLI.validatePushPayload(Data("[1,2]".utf8), bundleID: "x")) { error in
            XCTAssertTrue(error.localizedDescription.contains("JSON object at the top level"))
        }
        XCTAssertThrowsError(try CLI.validatePushPayload(Data("{\"aps\":".utf8), bundleID: "x")) { error in
            XCTAssertTrue(error.localizedDescription.contains("payload is not valid JSON:"))
        }
        let result = try CLI.validatePushPayload(Data("{\"aps\":{}}".utf8), bundleID: "com.example.app")
        XCTAssertEqual(result.bundle, "com.example.app")
        XCTAssertEqual(result.byteCount, 10)
    }

    func testPushTargetResolutionMatchesAcrossCliAndMCP() throws {
        let payload = #"{"aps":{},"Simulator Target Bundle":"com.b"}"#
        let cli = try CLI.parsePush(["com.a", "--payload", payload])
        let validated = try CLI.validatePushPayload(cli.data, bundleID: cli.bundleID)
        let invocation = try MCPServer.commandInvocation(tool: "send_push", arguments: ["payload": payload, "bundle_id": "com.a"])
        XCTAssertEqual(cli.targetBundle, "com.a")
        XCTAssertEqual(validated.bundle, "com.a")
        XCTAssertEqual(invocation.args.first, "com.a")
    }

    func testPushTargetResolutionUsesPayloadOrExplicitBundle() throws {
        let payloadTarget = try CLI.validatePushPayload(Data(#"{"aps":{},"Simulator Target Bundle":"com.b"}"#.utf8), bundleID: nil)
        let explicitTarget = try CLI.validatePushPayload(Data(#"{"aps":{}}"#.utf8), bundleID: "com.a")
        XCTAssertEqual(payloadTarget.bundle, "com.b")
        XCTAssertEqual(explicitTarget.bundle, "com.a")
        XCTAssertThrowsError(try CLI.validatePushPayload(Data(#"{"aps":{}}"#.utf8), bundleID: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("bundle id is required unless payload contains Simulator Target Bundle"))
        }
    }

    func testReadmeUsesCurrentDeviceDescription() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertTrue(text.contains("UDID or name; omit for the booted simulator"))
        XCTAssertFalse(text.contains("UDID, exact name, or partial name; omit to use the booted simulator"))
    }

    func testScenarioParserRemovesDuplicateRowsAndSorts() {
        XCTAssertEqual(CLI.parseScenarios("Name                 Description\nApple                Apple\nApple                Apple\n"), ["Apple"])
    }

    func testKeychainStagesContainerPathAndCleansUp() throws {
        let device = Device(udid: "U", name: "iPhone", state: "Booted", isAvailable: true)
        CLI.resolveDeviceForTesting = { _ in device }
        let source = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/test-cosmokit-(UUID().uuidString)/ca.pem")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("certificate".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var received: [String] = []
        CLI.runSimctlTimedForTesting = { args, _ in received = args; XCTAssertNotEqual(args.last, source.path); XCTAssertTrue(FileManager.default.fileExists(atPath: args.last!)); return "" }
        _ = try CLI.perform(command: "keychain", args: [source.path], output: nil)
        XCTAssertEqual(Array(received.prefix(3)), ["keychain", "U", "add-root-cert"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.last!))
    }

    func testKeychainMissingFileDoesNotInvokeSimctl() throws {
        CLI.resolveDeviceForTesting = { _ in Device(udid: "U", name: "iPhone", state: "Booted", isAvailable: true) }
        var invoked = false
        CLI.runSimctlTimedForTesting = { _, _ in invoked = true; return "" }
        XCTAssertThrowsError(try CLI.perform(command: "keychain", args: ["/tmp/does-not-exist.pem"], output: nil))
        XCTAssertFalse(invoked)
    }

    func testKeychainNormalPathAndFailureCleanup() throws {
        let device = Device(udid: "U", name: "iPhone", state: "Booted", isAvailable: true)
        CLI.resolveDeviceForTesting = { _ in device }
        let normal = FileManager.default.temporaryDirectory.appendingPathComponent("cosmokit-ca-(UUID().uuidString).pem")
        try Data("certificate".utf8).write(to: normal)
        defer { try? FileManager.default.removeItem(at: normal) }
        var normalArgs: [String] = []
        CLI.runSimctlTimedForTesting = { args, _ in normalArgs = args; return "" }
        _ = try CLI.perform(command: "keychain", args: [normal.path, "--untrusted"], output: nil)
        XCTAssertEqual(normalArgs.last, normal.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: normal.path))
        let source = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/test-cosmokit-(UUID().uuidString)/ca.pem")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("certificate".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var stagedPath = ""
        CLI.runSimctlTimedForTesting = { args, _ in stagedPath = args.last!; throw SimctlError(kind: .commandFailed, message: "failed") }
        XCTAssertThrowsError(try CLI.perform(command: "keychain", args: [source.path], output: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedPath))
    }

    func testKeychainAndProxyMCPMappings() throws {
        var calls: [(String, [String])] = []
        MCPServer.execute = { command, args, _ in calls.append((command, args)); return CommandOutcome(human: "ok", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"install_certificate","arguments":{"path":"/tmp/ca.pem","untrusted":true,"device":"U"}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reset_keychain","arguments":{}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"proxy_status","arguments":{}}}"#)
        XCTAssertEqual(calls.map { $0.0 }, ["keychain", "keychain-reset", "proxy-status"])
    }

    func testProxyStatusReadsSystemConfigurationShape() throws {
        let disabled: [String: Any] = ["HTTPEnable": 0, "HTTPSEnable": 0]
        let enabled: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "proxy.local", "HTTPPort": 8080, "HTTPSEnable": 1, "HTTPSProxy": "secure.local", "HTTPSPort": 8443, "ExceptionsList": ["localhost", "*.local"], "__SCOPED__": ["ignored": ["HTTPEnable": 1]]]
        XCTAssertFalse(CLI.parseProxyStatus(disabled).httpEnabled)
        let status = CLI.parseProxyStatus(enabled)
        XCTAssertEqual(status.httpsHost, "secure.local")
        XCTAssertEqual(status.httpsPort, 8443)
        XCTAssertEqual(status.bypassList, ["localhost", "*.local"])
        XCTAssertFalse(CLI.parseProxyStatus(nil).httpsEnabled)
        XCTAssertTrue(CLI.proxyHumanText(status).contains("HTTPS on at secure.local:8443"))
        XCTAssertTrue(CLI.proxyHumanText(status).contains("2 bypass rules"))
    }

    func testRealProxySourceContainsSystemConfigurationKeys() throws {
        let source = SCDynamicStoreCopyProxies(nil) as? [String: Any]
        XCTAssertNotNil(source)
        XCTAssertNotNil(source?["HTTPEnable"])
    }

    func testOversizedPushReportsPayloadSize() throws {
        let payload = String(repeating: "x", count: 5000)
        let arguments: [String: Any] = ["payload": ["aps": ["alert": payload]], "bundle_id": "x"]
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "send_push", "arguments": arguments]])
        let response = try object(for: String(decoding: data, as: UTF8.self))
        XCTAssertEqual(try toolErrorCode(response), "usage")
        XCTAssertTrue((try toolErrorMessage(response)).contains("bytes"))
    }

    func testRoutesAndScenarioParsingPreserveNames() throws {
        var received: [String] = []
        MCPServer.execute = { _, args, _ in received = args; return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_location_scenario","arguments":{"scenario":"City Run"}}}"#)
        XCTAssertEqual(received, ["City Run"])
        let table = """
        Name                 Description
        ========================================================
        City Run             City Run
        City Bicycle Ride    City Bicycle Ride
        Freeway Drive        Freeway Drive
        Apple                Apple
        """
        XCTAssertEqual(CLI.parseScenarios(table), ["Apple", "City Bicycle Ride", "City Run", "Freeway Drive"])
        XCTAssertEqual(CLI.parseScenarios("Name                 Description\n====================\n"), [])
        XCTAssertEqual(CLI.parseScenarios("Name                 Description\nCity Run             City Run   \n"), ["City Run"])
    }

    func testMediaAndPasteboardMappings() throws {
        var calls: [(String, [String])] = []
        MCPServer.execute = { command, args, _ in calls.append((command, args)); return CommandOutcome(human: "", json: EmptyPayload()) }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add_media","arguments":{"paths":"/tmp/photo.jpg"}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_pasteboard","arguments":{"text":"hello"}}}"#)
        _ = try object(for: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_pasteboard","arguments":{}}}"#)
        XCTAssertEqual(calls.map { $0.0 }, ["addmedia", "pasteboard", "pasteboard"])
        XCTAssertEqual(calls[0].1, ["/tmp/photo.jpg"])
        XCTAssertEqual(calls[1].1, ["--set", "hello"])
        XCTAssertEqual(calls[2].1, [])
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

    func testToolsListAdvertisesGroupedToolSurfaceAndSchemas() throws {
        let response = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let result = response["result"] as! [String: Any]
        let tools = result["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 35)
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, orderedToolNames)
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), toolNames)
        for tool in tools {
            XCTAssertTrue((tool["description"] as? String)?.count ?? 0 >= 40)
            let schema = tool["inputSchema"] as! [String: Any]
            XCTAssertEqual(schema["type"] as? String, "object")
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (propertyName, propertyValue) in properties {
                let property = propertyValue as! [String: Any]
                XCTAssertTrue(property["type"] is String || property["type"] is [String], "property \(propertyName) in \(tool["name"] ?? "?") has no type")
            }
            for required in schema["required"] as? [String] ?? [] {
                XCTAssertNotNil(properties[required], "required key \(required) missing from properties")
            }
        }
        let record = try tool(named: "record_video", in: tools)
        XCTAssertEqual(record["required"] as? [String], ["duration"])
        let capture = try tool(named: "capture_screenshot", in: tools)
        XCTAssertEqual(capture["required"] as? [String], [])
        let location = try tool(named: "set_location", in: tools)
        XCTAssertEqual(Set(location["required"] as? [String] ?? []), ["latitude", "longitude"])
    }

    func testToolsListStaysWithinItsContextBudget() throws {
        // The current response measured 13,307 bytes; 14,000 leaves about 5% for wording edits while making an unreviewed tool addition fail.
        let response = try XCTUnwrap(MCPServer.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let data = Data(response.utf8)
        let object = try jsonObject(response)
        let tools = (object["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 35)
        XCTAssertLessThan(data.count, 14_000)
    }

    func testDefaultsReadResolvesContainerBeforeExport() throws {
        let device = Device(udid: "UDID", name: "iPhone", state: "Booted", isAvailable: true)
        CLI.resolveDeviceForTesting = { _ in device }
        var calls: [[String]] = []
        CLI.runSimctlForTesting = { args in
            calls.append(args)
            if args.starts(with: ["get_app_container", "UDID", "com.example.app", "data"]) {
                return "/var/mobile/Containers/Data/Application/ABC\n"
            }
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>enabled</key><true/><key>count</key><integer>3</integer><key>title</key><string>Hello</string><key>items</key><array><string>a</string></array></dict></plist>"
        }
        let outcome = try CLI.perform(command: "defaults", args: ["com.example.app", "UDID"], output: nil)
        let envelope = try jsonObject(String(decoding: outcome.jsonData(), as: UTF8.self))
        XCTAssertEqual(calls, [
            ["get_app_container", "UDID", "com.example.app", "data"],
            ["spawn", "UDID", "defaults", "export", "/var/mobile/Containers/Data/Application/ABC/Library/Preferences/com.example.app", "-"]
        ])
        XCTAssertEqual((envelope["entries"] as? [[String: Any]])?.compactMap { $0["type"] as? String }, ["integer", "bool", "array", "string"])
    }

    func testMissingDefaultsPlistIsSuccessfulWithNote() throws {
        let device = Device(udid: "U", name: "iPhone", state: "Booted", isAvailable: true)
        CLI.resolveDeviceForTesting = { _ in device }
        CLI.runSimctlForTesting = { args in
            if args.first == "get_app_container" { return "/container" }
            throw SimctlError(kind: .commandFailed, message: "file does not exist")
        }
        let outcome = try CLI.perform(command: "defaults", args: ["com.example.app"], output: nil)
        let envelope = try jsonObject(String(decoding: outcome.jsonData(), as: UTF8.self))
        XCTAssertEqual((envelope["entries"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(envelope["note"] as? String, "The app has written no defaults yet")
    }

    func testDefaultWriteInferenceAndExplicitType() throws {
        var received: (String, [String])?
        MCPServer.execute = { command, args, _ in
            received = (command, args)
            return CommandOutcome(human: "ok", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_default","arguments":{"bundle_id":"com.example.app","key":"enabled","value":true}}}"#)
        XCTAssertEqual(received?.0, "defaults-write")
        XCTAssertEqual(received?.1, ["com.example.app", "enabled", "true", "--type", "bool"])
        _ = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write_default","arguments":{"bundle_id":"com.example.app","key":"count","value":3}}}"#)
        XCTAssertEqual(received?.1, ["com.example.app", "count", "3", "--type", "int"])
        _ = try object(for: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"write_default","arguments":{"bundle_id":"com.example.app","key":"ratio","value":1.5}}}"#)
        XCTAssertEqual(received?.1, ["com.example.app", "ratio", "1.5", "--type", "float"])
        _ = try object(for: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"write_default","arguments":{"bundle_id":"com.example.app","key":"count","value":3,"type":"string"}}}"#)
        XCTAssertEqual(received?.1, ["com.example.app", "count", "3", "--type", "string"])
        let invalid = try object(for: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"write_default","arguments":{"bundle_id":"x","key":"k","value":true,"type":"bogus"}}}"#)
        XCTAssertEqual(try toolErrorCode(invalid), "usage")
    }

    func testLogsValidateWindowPredicateAndBoundLines() throws {
        var received: [String] = []
        MCPServer.execute = { command, args, _ in
            received = args
            return CommandOutcome(human: "logs", json: EmptyPayload())
        }
        _ = try object(for: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_logs","arguments":{"bundle_id":"com.example.app"}}}"#)
        XCTAssertEqual(received, ["--bundle", "com.example.app"])
        let invalid = try object(for: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_logs","arguments":{"last":"banana"}}}"#)
        XCTAssertEqual(try toolErrorCode(invalid), "usage")
        let lines = (1...900).map(String.init).joined(separator: "\n")
        let parsed = CLI.parseLogLines(lines)
        let bounded = Array(parsed.suffix(500))
        XCTAssertEqual(bounded.count, 500)
        XCTAssertEqual(parsed.count, 900)
        XCTAssertEqual(bounded.first, "401")
    }

    func testRuntimesDoesNotResolveDevice() throws {
        CLI.resolveDeviceForTesting = { _ in XCTFail("runtimes must not resolve a device"); return Device(udid: "", name: "", state: "", isAvailable: false) }
        var calls: [[String]] = []
        CLI.runSimctlForTesting = { args in
            calls.append(args)
            if args == ["list", "runtimes", "--json"] { return #"{"runtimes":[]}"# }
            return #"{"devicetypes":[]}"#
        }
        _ = try CLI.perform(command: "runtimes", args: [], output: nil)
        XCTAssertEqual(calls, [["list", "runtimes", "--json"], ["list", "devicetypes", "--json"]])
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

    private func toolErrorMessage(_ response: [String: Any]) throws -> String {
        try ((jsonObject(toolText(response))["error"] as? [String: Any])?["message"] as? String) ?? ""
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
