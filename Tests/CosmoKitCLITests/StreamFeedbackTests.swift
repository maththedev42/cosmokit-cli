import XCTest
@testable import CosmoKitCLI

final class StreamFeedbackTests: XCTestCase {
    override func tearDown() {
        FeedbackStore.baseDirectoryOverride = nil
        StreamServer.driverClient = DefaultDriverClient()
        super.tearDown()
    }

    func testFeedbackLineRendersUnder600Bytes() throws {
        let element = FeedbackElementPayload(
            ref: 7,
            type: "Button",
            label: "Continue",
            identifier: "cta.continue",
            frame: UITreeFrame(x: 187, y: 612, width: 280, height: 44)
        )
        let record = FeedbackRecordPayload(
            seq: 3,
            at: "2026-09-08T15:00:00Z",
            x: 187,
            y: 612,
            element: element,
            text: "This should be disabled until the form is valid",
            frame: "/Users/developer/Library/Application Support/cosmokit/feedback/SIM-UDID-12345/3.png",
            branch: "feat/x",
            worktree: "/Users/developer/Projects/CosmoKit",
            app: "com.example.app",
            udid: "SIM-UDID-12345",
            acked: false
        )

        let line = FeedbackStore.formatCompact(record)
        let byteCount = Data(line.utf8).count

        XCTAssertLessThanOrEqual(byteCount, 600, "Feedback line should be under 600 bytes, was \(byteCount)")
        XCTAssertTrue(line.contains("#3 on [7] Button \"Continue\" (id: cta.continue) at (187,612) — \"This should be disabled until the form is valid\""))
        XCTAssertTrue(line.contains("branch: feat/x"))
    }

    func testPostFeedbackWithoutTokenPathIsRejectedWith404() throws {
        let validToken = "a1b2c3d4e5f6"
        let payload = #"{"x": 100, "y": 200, "text": "Hello agent"}"#.data(using: .utf8)

        // 1. Without any token prefix
        let res1 = StreamServer.processRequest(
            method: "POST",
            uri: "/feedback",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res1.statusCode, 404)

        // 2. With wrong token
        let res2 = StreamServer.processRequest(
            method: "POST",
            uri: "/s/wrongtoken123/feedback",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res2.statusCode, 404)

        // 3. With valid token
        let res3 = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/feedback",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res3.statusCode, 200)
    }

    func testPointToElementResolutionPicksDeepestContainerFreeMatch() throws {
        // Construct hierarchy:
        // Window (container, 0,0 400x800) -> depth 0
        //   ScrollView (container, 0,50 400x700) -> depth 1
        //     Other (container, 10,60 380x600) -> depth 2
        //       StaticText "Header" (10,60 200x30) -> depth 3
        //       Button "Submit" (10,120 200x50, ref 42) -> depth 3
        //         LayoutItem (container inside button, 10,120 200x50) -> depth 4
        let innerContainer = UIElement(
            ref: 43,
            type: "LayoutItem",
            frame: UITreeFrame(x: 10, y: 120, width: 200, height: 50)
        )
        let button = UIElement(
            ref: 42,
            type: "Button",
            identifier: "btn.submit",
            label: "Submit",
            frame: UITreeFrame(x: 10, y: 120, width: 200, height: 50),
            children: [innerContainer]
        )
        let header = UIElement(
            ref: 10,
            type: "StaticText",
            label: "Header",
            frame: UITreeFrame(x: 10, y: 60, width: 200, height: 30)
        )
        let otherView = UIElement(
            ref: 5,
            type: "Other",
            frame: UITreeFrame(x: 10, y: 60, width: 380, height: 600),
            children: [header, button]
        )
        let scrollView = UIElement(
            ref: 2,
            type: "ScrollView",
            frame: UITreeFrame(x: 0, y: 50, width: 400, height: 700),
            children: [otherView]
        )
        let window = UIElement(
            ref: 1,
            type: "Window",
            frame: UITreeFrame(x: 0, y: 0, width: 400, height: 800),
            children: [scrollView]
        )
        let snapshot = UISnapshot(app: "com.example.app", elements: [window])

        // Tap point inside button (x: 50, y: 140)
        let resolved = FeedbackStore.resolveElement(in: snapshot, x: 50, y: 140)

        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.ref, 42)
        XCTAssertEqual(resolved?.type, "Button")
        XCTAssertEqual(resolved?.label, "Submit")
    }

    func testFeedbackStoreCRUD() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FeedbackStore.baseDirectoryOverride = tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let udid = "SIM-TEST-CRUD"
        let elem = FeedbackElementPayload(ref: 1, type: "Button", label: "OK")

        let rec1 = try FeedbackStore.append(
            udid: udid, x: 10, y: 20, element: elem, text: "First comment",
            framePath: "/tmp/1.png", branch: "main", worktree: "/repo", app: "com.app"
        )
        XCTAssertEqual(rec1.seq, 1)
        XCTAssertEqual(rec1.acked, false)

        let rec2 = try FeedbackStore.append(
            udid: udid, x: 30, y: 40, element: elem, text: "Second comment",
            framePath: "/tmp/2.png", branch: "main", worktree: "/repo", app: "com.app"
        )
        XCTAssertEqual(rec2.seq, 2)

        let all = FeedbackStore.readAll(udid: udid)
        XCTAssertEqual(all.count, 2)

        let acked1 = try FeedbackStore.ack(udid: udid, seq: 1)
        XCTAssertEqual(acked1?.acked, true)

        let nextUnread = FeedbackStore.nextUnread(udid: udid, wait: 0)
        XCTAssertEqual(nextUnread?.seq, 2)

        let cleared = try FeedbackStore.clear(udid: udid)
        XCTAssertEqual(cleared, 2)
        XCTAssertEqual(FeedbackStore.readAll(udid: udid).count, 0)
    }

    func testMCPInvocationForAgentStreamAndFeedback() throws {
        // agent_stream start
        let inv1 = try MCPServer.commandInvocation(tool: "agent_stream", arguments: ["port": 9000, "device": "iPhone"])
        XCTAssertEqual(inv1.command, "agent")
        XCTAssertEqual(inv1.args, ["stream", "--daemon", "iPhone", "--port", "9000"])

        // agent_stream stop
        let inv2 = try MCPServer.commandInvocation(tool: "agent_stream", arguments: ["action": "stop", "device": "iPhone"])
        XCTAssertEqual(inv2.command, "agent")
        XCTAssertEqual(inv2.args, ["stream", "stop", "iPhone"])

        // feedback next
        let inv3 = try MCPServer.commandInvocation(tool: "feedback", arguments: ["action": "next", "wait": 10])
        XCTAssertEqual(inv3.command, "feedback")
        XCTAssertEqual(inv3.args, ["next", "--wait", "10"])

        // feedback ack
        let inv4 = try MCPServer.commandInvocation(tool: "feedback", arguments: ["action": "ack", "seq": 5])
        XCTAssertEqual(inv4.command, "feedback")
        XCTAssertEqual(inv4.args, ["ack", "5"])
    }

    func testActEndpointRejectsMissingOrWrongTokenWith404() throws {
        let validToken = "token1234567"
        let payload = #"{"action": "tap", "x": 100, "y": 200}"#.data(using: .utf8)

        // Missing token
        let res1 = StreamServer.processRequest(
            method: "POST",
            uri: "/act",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res1.statusCode, 404)

        // Wrong token
        let res2 = StreamServer.processRequest(
            method: "POST",
            uri: "/s/wrongtoken/act",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res2.statusCode, 404)
    }

    func testActEndpointReturnsDriverUnavailableWhenDriverNotRunning() throws {
        let validToken = "token1234567"
        let mock = MockDriverClient(isRunning: false)
        StreamServer.driverClient = mock

        let payload = #"{"action": "tap", "x": 100, "y": 200}"#.data(using: .utf8)
        let res = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res.statusCode, 200)

        guard let json = try? JSONSerialization.jsonObject(with: res.body) as? [String: Any],
              let ok = json["ok"] as? Bool,
              let error = json["error"] as? [String: Any],
              let code = error["code"] as? String else {
            XCTFail("Expected driverUnavailable error envelope")
            return
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(code, "driverUnavailable")
    }

    func testActEndpointRejectsUnknownActionWith400() throws {
        let validToken = "token1234567"
        let mock = MockDriverClient(isRunning: true)
        StreamServer.driverClient = mock

        let payload = #"{"action": "dance"}"#.data(using: .utf8)
        let res = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res.statusCode, 400)

        guard let json = try? JSONSerialization.jsonObject(with: res.body) as? [String: Any],
              let ok = json["ok"] as? Bool,
              let error = json["error"] as? [String: Any],
              let code = error["code"] as? String else {
            XCTFail("Expected badAction error envelope")
            return
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(code, "badAction")
    }

    func testActEndpointConvertsPagePxToPointsWithScale() throws {
        let validToken = "token1234567"
        let mock = MockDriverClient(isRunning: true)
        StreamServer.driverClient = mock

        var postActCalled = false

        // Tap test: 100, 200 px at scale 0.5 -> 200, 400 pt
        let tapPayload = #"{"action": "tap", "x": 100, "y": 200}"#.data(using: .utf8)
        let tapRes = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: tapPayload,
            token: validToken,
            udid: "TEST-UDID",
            scale: 0.5,
            onPostAct: { postActCalled = true }
        )
        XCTAssertEqual(tapRes.statusCode, 200)
        XCTAssertTrue(postActCalled)
        XCTAssertEqual(mock.recordedCalls.count, 1)
        XCTAssertEqual(mock.recordedCalls[0].path, "/tap")
        XCTAssertEqual(mock.recordedCalls[0].json?["x"] as? Double, 200.0)
        XCTAssertEqual(mock.recordedCalls[0].json?["y"] as? Double, 400.0)

        postActCalled = false
        // Swipe test: 10, 20 to 50, 60 px at scale 0.5 -> 20, 40 to 100, 120 pt
        let swipePayload = #"{"action": "swipe", "x1": 10, "y1": 20, "x2": 50, "y2": 60, "duration": 0.5}"#.data(using: .utf8)
        let swipeRes = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: swipePayload,
            token: validToken,
            udid: "TEST-UDID",
            scale: 0.5,
            onPostAct: { postActCalled = true }
        )
        XCTAssertEqual(swipeRes.statusCode, 200)
        XCTAssertTrue(postActCalled)
        XCTAssertEqual(mock.recordedCalls.count, 2)
        XCTAssertEqual(mock.recordedCalls[1].path, "/swipe")
        XCTAssertEqual(mock.recordedCalls[1].json?["x1"] as? Double, 20.0)
        XCTAssertEqual(mock.recordedCalls[1].json?["y1"] as? Double, 40.0)
        XCTAssertEqual(mock.recordedCalls[1].json?["x2"] as? Double, 100.0)
        XCTAssertEqual(mock.recordedCalls[1].json?["y2"] as? Double, 120.0)
        XCTAssertEqual(mock.recordedCalls[1].json?["duration"] as? Double, 0.5)
    }

    func testActEndpointCapsTextAt2000Chars() throws {
        let validToken = "token1234567"
        let mock = MockDriverClient(isRunning: true)
        StreamServer.driverClient = mock

        let longText = String(repeating: "A", count: 2500)
        let payload = try JSONSerialization.data(withJSONObject: ["action": "type", "text": longText])
        let res = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: payload,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(res.statusCode, 200)
        XCTAssertEqual(mock.recordedCalls.count, 1)
        XCTAssertEqual(mock.recordedCalls[0].path, "/type")
        let sentText = mock.recordedCalls[0].json?["text"] as? String
        XCTAssertEqual(sentText?.count, 2000)
    }

    func testActEndpointHardwareButtons() throws {
        let validToken = "token1234567"
        let mock = MockDriverClient(isRunning: true)
        StreamServer.driverClient = mock

        // Valid button
        let payloadHome = #"{"action": "button", "name": "home"}"#.data(using: .utf8)
        let resHome = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: payloadHome,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(resHome.statusCode, 200)
        XCTAssertEqual(mock.recordedCalls.count, 1)
        XCTAssertEqual(mock.recordedCalls[0].path, "/button")
        XCTAssertEqual(mock.recordedCalls[0].json?["name"] as? String, "home")

        // Invalid button -> 400
        let payloadInvalid = #"{"action": "button", "name": "powerOff"}"#.data(using: .utf8)
        let resInvalid = StreamServer.processRequest(
            method: "POST",
            uri: "/s/\(validToken)/act",
            body: payloadInvalid,
            token: validToken,
            udid: "TEST-UDID"
        )
        XCTAssertEqual(resInvalid.statusCode, 400)
    }

    func testFeedbackPromptFormatterSnapshotAllOptionalsNil() throws {
        let element = FeedbackElementPayload(
            ref: 1,
            type: "View",
            label: nil,
            identifier: nil,
            frame: nil
        )
        let record = FeedbackRecordPayload(
            seq: 1,
            at: "2026-09-08T15:00:00Z",
            x: 100,
            y: 200,
            element: element,
            text: "Need fix",
            frame: "/tmp/feedback/1.png",
            branch: nil,
            worktree: nil,
            app: nil,
            udid: "12345678-ABCD-EF01-2345-6789ABCDEF01",
            acked: false
        )
        let output = FeedbackPrompt.render([record], app: nil)
        let expected = """
        ## Feedback #1 — app on 12345678
        Element: View "" (id: —, ref 1, frame —)
        Point: (100,200) pt
        Note: Need fix
        Screenshot: /tmp/feedback/1.png
        Branch: —  Worktree: —

        To act on this: `cosmokit ui tree --mode act` then `cosmokit ui tap <ref> --screen <hash>`.
        Mark done with `cosmokit feedback ack <seq>`.
        """
        XCTAssertEqual(output, expected)
    }

    func testFeedbackPromptFormatterSnapshotAllOptionalsSet() throws {
        let element = FeedbackElementPayload(
            ref: 7,
            type: "Button",
            label: "Continue with `Pro`",
            identifier: "cta.continue",
            frame: UITreeFrame(x: 187, y: 612, width: 280, height: 44)
        )
        let record = FeedbackRecordPayload(
            seq: 3,
            at: "2026-09-08T15:00:00Z",
            x: 187.4,
            y: 612.6,
            element: element,
            text: "This button should say `Upgrade` instead of `Continue`",
            frame: "/Users/developer/Library/Application Support/cosmokit/feedback/SIM-UDID-12345/3.png",
            branch: "feat/pro-upsell",
            worktree: "/Users/developer/Projects/CosmoKit",
            app: "com.example.cosmokit",
            udid: "B5029438-33A9-47E0-ACA4-C7B790A12E64",
            acked: false
        )
        let output = FeedbackPrompt.render([record], app: "com.fallback.app")
        let expected = """
        ## Feedback #3 — com.example.cosmokit on B5029438
        Element: Button "Continue with \\`Pro\\`" (id: cta.continue, ref 7, frame 187,612 280×44)
        Point: (187,613) pt
        Note: This button should say \\`Upgrade\\` instead of \\`Continue\\`
        Screenshot: /Users/developer/Library/Application Support/cosmokit/feedback/SIM-UDID-12345/3.png
        Branch: feat/pro-upsell  Worktree: /Users/developer/Projects/CosmoKit

        To act on this: `cosmokit ui tree --mode act` then `cosmokit ui tap <ref> --screen <hash>`.
        Mark done with `cosmokit feedback ack <seq>`.
        """
        XCTAssertEqual(output, expected)
    }

    func testFeedbackPromptEmptySelectionReturnsNoFeedback() throws {
        let output = FeedbackPrompt.render([], app: nil)
        XCTAssertEqual(output, "No feedback to render.")
    }

    func testFeedbackPromptMissingSeqErrorsWithUsageCode() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FeedbackStore.baseDirectoryOverride = tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let device = Device(udid: "UDID-MISSING-TEST", name: "iPhone 16", state: "Booted", isAvailable: true)
        CLI.resolveDeviceForTesting = { _ in device }

        XCTAssertThrowsError(try CLI.perform(command: "feedback", args: ["prompt", "--seq", "999"])) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .usage)
            XCTAssertEqual(cliError.commandError.message, "no feedback record with seq #999")
        }
    }

    func testFeedbackPromptCLIvsHTTPByteIdentity() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FeedbackStore.baseDirectoryOverride = tempDir
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let udid = "SIM-BYTE-IDENTITY"
        let device = Device(udid: udid, name: "iPhone 16 Pro", state: "Booted", isAvailable: true)
        CLI.resolveDeviceForTesting = { _ in device }

        let element = FeedbackElementPayload(
            ref: 4,
            type: "Button",
            label: "Submit",
            identifier: "form.submit",
            frame: UITreeFrame(x: 20, y: 100, width: 200, height: 50)
        )
        _ = try FeedbackStore.append(
            udid: udid,
            x: 50,
            y: 120,
            element: element,
            text: "Fix submit validation",
            framePath: "/tmp/1.png",
            branch: "main",
            worktree: "/Users/dev/repo",
            app: "com.example.app"
        )

        let cliOutcome = try CLI.perform(command: "feedback", args: ["prompt", "--unacked", udid])
        let cliText = cliOutcome.human

        let httpResponse = StreamServer.processRequest(
            method: "GET",
            uri: "/s/token123/feedback/prompt?scope=unacked",
            body: nil,
            token: "token123",
            udid: udid,
            deviceName: "iPhone 16 Pro",
            app: "com.example.app"
        )
        XCTAssertEqual(httpResponse.statusCode, 200)
        let httpText = String(decoding: httpResponse.body, as: UTF8.self)

        XCTAssertEqual(cliText, httpText)
        XCTAssertEqual(Data(cliText.utf8), httpResponse.body)
    }

    func testMCPInvocationForFeedbackPrompt() throws {
        var received: (String, [String], String?)?
        MCPServer.execute = { command, args, output in
            received = (command, args, output)
            return CommandOutcome(human: "rendered", json: FeedbackPromptPayload(text: "rendered"))
        }

        // Test action: prompt with seq
        _ = MCPServer.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"feedback","arguments":{"action":"prompt","seq":3}}}"#)
        XCTAssertEqual(received?.0, "feedback")
        XCTAssertEqual(received?.1, ["prompt", "--seq", "3"])

        // Test action: prompt with scope unacked
        _ = MCPServer.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"feedback","arguments":{"action":"prompt","scope":"unacked"}}}"#)
        XCTAssertEqual(received?.0, "feedback")
        XCTAssertEqual(received?.1, ["prompt", "--unacked"])

        // Test action: prompt with scope all
        _ = MCPServer.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"feedback","arguments":{"action":"prompt","scope":"all"}}}"#)
        XCTAssertEqual(received?.0, "feedback")
        XCTAssertEqual(received?.1, ["prompt", "--all"])
    }
}

private final class MockDriverClient: DriverClientType {
    var isRunning: Bool
    struct CallRecord {
        let path: String
        let method: String
        let json: [String: Any]?
    }
    var recordedCalls: [CallRecord] = []

    init(isRunning: Bool) {
        self.isRunning = isRunning
    }

    func status(device: String?) -> DriverStatusPayload {
        DriverStatusPayload(running: isRunning, port: isRunning ? 8877 : nil, pid: isRunning ? 1234 : nil)
    }

    func call(_ path: String, method: String, json: [String: Any]?) throws -> Data {
        recordedCalls.append(CallRecord(path: path, method: method, json: json))
        return Data("{\"ok\":true}".utf8)
    }
}
