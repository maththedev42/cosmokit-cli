//
//  AppControlTests.swift
//  CosmoKitCLITests
//
//  AGT-08: Tests for loopback control endpoint client, error mappings, and commands.
//

import XCTest
@testable import CosmoKitCLI

final class AppControlTests: XCTestCase {

    private var tempDirectory: URL!
    private var controlFileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        controlFileURL = tempDirectory.appendingPathComponent("agent-control.json")
        AppControl.controlFileURLOverride = controlFileURL
        AppControl.isPidAliveForTesting = nil
        AppControl.httpForTesting = nil
    }

    override func tearDownWithError() throws {
        AppControl.controlFileURLOverride = nil
        AppControl.isPidAliveForTesting = nil
        AppControl.httpForTesting = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func writeControlFile(pid: Int = 12345, port: Int = 54321, token: String = "testtoken123", version: String = "4.8.0") throws {
        let json: [String: Any] = [
            "pid": pid,
            "port": port,
            "token": token,
            "version": version
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: controlFileURL)
    }

    func testAppNotRunningWhenControlFileMissing() {
        XCTAssertThrowsError(try AppControl.readControlInfo()) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .appNotRunning)
            XCTAssertEqual(cliError.commandError.hint, "Open CosmoKit")
        }
    }

    func testAppNotRunningWhenPidIsDead() throws {
        try writeControlFile(pid: 999999)
        AppControl.isPidAliveForTesting = { pid in
            XCTAssertEqual(pid, 999999)
            return false
        }

        XCTAssertThrowsError(try AppControl.readControlInfo()) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .appNotRunning)
            XCTAssertEqual(cliError.commandError.hint, "Open CosmoKit")
        }
    }

    func testAppTooOldWhenVersionIsLessThanMinimum() throws {
        try writeControlFile(pid: 12345, version: "4.7.9")
        AppControl.isPidAliveForTesting = { _ in true }

        XCTAssertThrowsError(try AppControl.readControlInfo()) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .appTooOld)
            XCTAssertTrue(cliError.commandError.hint?.contains("4.8.0") == true)
            XCTAssertTrue(cliError.commandError.hint?.contains("4.7.9") == true)
        }
    }

    func testProxyNotRunningOn409Response() throws {
        try writeControlFile(pid: 12345, port: 54321, token: "tok123", version: "4.8.0")
        AppControl.isPidAliveForTesting = { _ in true }

        let responseJSON = """
        {"ok":false,"error":{"code":"proxyNotRunning","hint":"Start the proxy in CosmoKit → Network"}}
        """
        AppControl.httpForTesting = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
            return (Data(responseJSON.utf8), 409)
        }

        XCTAssertThrowsError(try AppControl.throttle(preset: "edge", custom: nil)) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .proxyNotRunning)
            XCTAssertEqual(cliError.commandError.hint, "Start the proxy in CosmoKit → Network")
        }
    }

    func testSuccessfulStatusAndThrottleCalls() throws {
        try writeControlFile(pid: 12345, port: 54321, token: "tok123", version: "4.8.0")
        AppControl.isPidAliveForTesting = { _ in true }

        let statusJSON = """
        {
            "ok": true,
            "proxy": {"running": true, "port": 8899},
            "conditions": {
                "preset": "edge",
                "latencyMs": 300,
                "downloadKbps": 240,
                "uploadKbps": 200,
                "failureRatePercent": 0,
                "failureMode": "drop",
                "timeoutSeconds": 30
            },
            "offline": false
        }
        """

        var lastRequest: URLRequest?
        AppControl.httpForTesting = { request in
            lastRequest = request
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
            return (Data(statusJSON.utf8), 200)
        }

        // Test status
        let status = try AppControl.status()
        XCTAssertEqual(status.proxy.running, true)
        XCTAssertEqual(status.proxy.port, 8899)
        XCTAssertEqual(status.conditions.preset, "edge")
        XCTAssertEqual(status.conditions.latencyMs, 300)
        XCTAssertEqual(status.offline, false)
        XCTAssertEqual(lastRequest?.url?.path, "/v1/status")
        XCTAssertEqual(lastRequest?.httpMethod, "GET")

        // Test throttle preset
        let throttled = try AppControl.throttle(preset: "threeG", custom: nil)
        XCTAssertEqual(throttled.conditions.preset, "edge")
        XCTAssertEqual(lastRequest?.url?.path, "/v1/throttle")
        XCTAssertEqual(lastRequest?.httpMethod, "POST")
        if let body = lastRequest?.httpBody,
           let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(dict["preset"] as? String, "threeG")
        } else {
            XCTFail("Expected JSON body")
        }

        // Test offline toggle
        _ = try AppControl.offline(on: true)
        XCTAssertEqual(lastRequest?.url?.path, "/v1/offline")
        XCTAssertEqual(lastRequest?.httpMethod, "POST")
        if let body = lastRequest?.httpBody,
           let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(dict["on"] as? Bool, true)
        } else {
            XCTFail("Expected JSON body")
        }
    }

    func testCLIThrottleAndOfflineCommands() throws {
        try writeControlFile(pid: 12345, port: 54321, token: "tok123", version: "4.8.0")
        AppControl.isPidAliveForTesting = { _ in true }

        let statusJSON = """
        {
            "ok": true,
            "proxy": {"running": true, "port": 8899},
            "conditions": {
                "preset": "threeG",
                "latencyMs": 100,
                "downloadKbps": 1600,
                "uploadKbps": 768,
                "failureRatePercent": 0
            },
            "offline": false
        }
        """

        var capturedBodies: [[String: Any]] = []
        AppControl.httpForTesting = { request in
            if let body = request.httpBody,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBodies.append(dict)
            }
            return (Data(statusJSON.utf8), 200)
        }

        // CLI throttle 3g
        let outcome3g = try CLI.perform(command: "throttle", args: ["3g"], output: nil)
        XCTAssertTrue(outcome3g.human.contains("preset: threeG"))
        XCTAssertEqual(capturedBodies.last?["preset"] as? String, "threeG")

        // CLI throttle custom
        let outcomeCustom = try CLI.perform(command: "throttle", args: ["custom", "--latency-ms", "150", "--down-kbps", "5000", "--up-kbps", "2000", "--failure-pct", "5"], output: nil)
        XCTAssertTrue(outcomeCustom.human.contains("Network conditions:"))
        if let customDict = capturedBodies.last?["custom"] as? [String: Any] {
            XCTAssertEqual(customDict["latencyMs"] as? Int, 150)
            XCTAssertEqual(customDict["downloadKbps"] as? Int, 5000)
            XCTAssertEqual(customDict["uploadKbps"] as? Int, 2000)
            XCTAssertEqual(customDict["failureRatePercent"] as? Int, 5)
        } else {
            XCTFail("Expected custom dict in body")
        }

        // CLI offline on
        let outcomeOfflineOn = try CLI.perform(command: "offline", args: ["on"], output: nil)
        XCTAssertTrue(outcomeOfflineOn.human.contains("Network conditions:"))
        XCTAssertEqual(capturedBodies.last?["on"] as? Bool, true)

        // CLI offline off
        let outcomeOfflineOff = try CLI.perform(command: "offline", args: ["off"], output: nil)
        XCTAssertTrue(outcomeOfflineOff.human.contains("Network conditions:"))
        XCTAssertEqual(capturedBodies.last?["on"] as? Bool, false)
    }

    func testMCPNetworkConditionsInvocation() throws {
        // Status
        let (cmdStatus, argsStatus, _) = try MCPServer.commandInvocation(tool: "network_conditions", arguments: ["action": "status"])
        XCTAssertEqual(cmdStatus, "throttle")
        XCTAssertEqual(argsStatus, ["status"])

        // Throttle preset
        let (cmdPreset, argsPreset, _) = try MCPServer.commandInvocation(tool: "network_conditions", arguments: ["action": "throttle", "preset": "edge"])
        XCTAssertEqual(cmdPreset, "throttle")
        XCTAssertEqual(argsPreset, ["edge"])

        // Throttle custom
        let (cmdCustom, argsCustom, _) = try MCPServer.commandInvocation(tool: "network_conditions", arguments: [
            "action": "throttle",
            "custom": [
                "latency_ms": 250,
                "download_kbps": 1200
            ]
        ])
        XCTAssertEqual(cmdCustom, "throttle")
        XCTAssertEqual(argsCustom, ["custom", "--latency-ms", "250", "--down-kbps", "1200"])

        // Offline
        let (cmdOffline, argsOffline, _) = try MCPServer.commandInvocation(tool: "network_conditions", arguments: ["action": "offline", "on": true])
        XCTAssertEqual(cmdOffline, "offline")
        XCTAssertEqual(argsOffline, ["on"])
    }
}
