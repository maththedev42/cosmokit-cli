import XCTest
@testable import CosmoKitCLI

final class ScreenGuardTests: XCTestCase {
    private let defaultHTTP = Driver.httpForTesting

    override func tearDown() {
        Driver.httpForTesting = defaultHTTP
        super.tearDown()
    }

    func testScreenHashStabilityAndLabelChange() throws {
        let btn1 = UIElement(ref: 1, type: "Button", identifier: "login.cta", label: "Log In", frame: UITreeFrame(x: 10, y: 100, width: 200, height: 44))
        let btn2 = UIElement(ref: 2, type: "Button", identifier: "signup.cta", label: "Sign Up", frame: UITreeFrame(x: 10, y: 160, width: 200, height: 44))
        
        let snapshot1 = UISnapshot(app: "com.test.app", elements: [btn1, btn2])
        let snapshot2 = UISnapshot(app: "com.test.app", elements: [btn1, btn2])
        
        let hash1 = UITree.screenHash(snapshot1)
        let hash2 = UITree.screenHash(snapshot2)
        
        XCTAssertEqual(hash1.count, 8)
        XCTAssertEqual(hash1, hash2, "Screen hash must be identical for identical snapshots")
        
        // Change label on btn1
        let btn1Modified = UIElement(ref: 1, type: "Button", identifier: "login.cta", label: "Sign In", frame: UITreeFrame(x: 10, y: 100, width: 200, height: 44))
        let snapshot3 = UISnapshot(app: "com.test.app", elements: [btn1Modified, btn2])
        let hash3 = UITree.screenHash(snapshot3)
        
        XCTAssertNotEqual(hash1, hash3, "Screen hash must change when an element label changes")
    }

    func testScreenMismatchThrowsScreenChangedError() throws {
        let btn = UIElement(ref: 1, type: "Button", identifier: "cta", label: "Press Me", frame: UITreeFrame(x: 0, y: 0, width: 100, height: 40))
        let snapshot = UISnapshot(app: "com.test.app", elements: [btn])
        let actualHash = UITree.screenHash(snapshot)
        let snapshotData = try JSONEncoder().encode(snapshot)

        Driver.httpForTesting = { method, url, body in
            if url.path == "/tree" {
                return (snapshotData, 200)
            }
            return (#"{"ok":true}"#.data(using: .utf8)!, 200)
        }

        // Action with incorrect screen hash
        XCTAssertThrowsError(try CLI.perform(command: "ui", args: ["tap", "1", "--screen", "00000000"])) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .screenChanged)
            XCTAssertEqual(cliError.commandError.expected, "00000000")
            XCTAssertEqual(cliError.commandError.actual, actualHash)
        }

        // Action with correct screen hash should succeed
        XCTAssertNoThrow(try CLI.perform(command: "ui", args: ["tap", "1", "--screen", actualHash]))
    }

    func testWaitWithGoneSucceedsWhenElementIsAbsent() throws {
        let snapshot = UISnapshot(app: "com.test.app", elements: [])
        let snapshotData = try JSONEncoder().encode(snapshot)
        let expectedHash = UITree.screenHash(snapshot)

        Driver.httpForTesting = { method, url, body in
            if url.path == "/tree" {
                return (snapshotData, 200)
            }
            return (Data(), 200)
        }

        let outcome = try CLI.perform(command: "ui", args: ["wait", "NonExistentButton", "--gone", "--timeout", "1", "--interval", "0.05"])
        XCTAssertTrue(outcome.human.contains("screen: \(expectedHash)"))
        XCTAssertTrue(outcome.human.contains("gone: \"NonExistentButton\""))
    }

    func testDoStopsAtStepTwoOfThreeWithIndex() throws {
        let btn1 = UIElement(ref: 1, type: "Button", label: "First", frame: UITreeFrame(x: 0, y: 0, width: 100, height: 40))
        let snapshot = UISnapshot(app: "com.test.app", elements: [btn1])
        let snapshotData = try JSONEncoder().encode(snapshot)

        var callCount = 0
        Driver.httpForTesting = { method, url, body in
            if url.path == "/tree" {
                return (snapshotData, 200)
            }
            if url.path == "/tap" {
                callCount += 1
                if callCount == 2 {
                    throw NSError(domain: "DriverError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Ref 9999 not found"])
                }
                return (#"{"ok":true}"#.data(using: .utf8)!, 200)
            }
            return (#"{"ok":true}"#.data(using: .utf8)!, 200)
        }

        // 3 steps: step 1 passes, step 2 fails, step 3 should never run
        XCTAssertThrowsError(try CLI.perform(command: "ui", args: ["do", "tap 1", "tap 9999", "tap 1"])) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            let message = cliError.commandError.message
            XCTAssertTrue(message.contains("Step 2 of 3 failed"), "Expected message to identify step 2 of 3 failed, got: \(message)")
        }

        XCTAssertEqual(callCount, 2, "Should not have executed step 3")
    }

    func testMCPInvocationForUIWaitAndUIDo() throws {
        // ui_wait
        let invWait = try MCPServer.commandInvocation(tool: "ui_wait", arguments: [
            "text": "Submit",
            "timeout": 5.0,
            "gone": true
        ])
        XCTAssertEqual(invWait.command, "ui")
        XCTAssertEqual(invWait.args, ["wait", "Submit", "--timeout", "5", "--gone"])

        // ui_do
        let invDo = try MCPServer.commandInvocation(tool: "ui_do", arguments: [
            "steps": ["tap 1", "wait \"Done\""],
            "screen": "a1b2c3d4"
        ])
        XCTAssertEqual(invDo.command, "ui")
        XCTAssertEqual(invDo.args, ["do", "--screen", "a1b2c3d4", "tap 1", "wait \"Done\""])

        // ui_tap with screen
        let invTap = try MCPServer.commandInvocation(tool: "ui_tap", arguments: [
            "ref": 3,
            "screen": "deadbeef"
        ])
        XCTAssertEqual(invTap.command, "ui")
        XCTAssertEqual(invTap.args, ["tap", "3", "--screen", "deadbeef"])
    }
}
