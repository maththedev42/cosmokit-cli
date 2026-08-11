import XCTest
@testable import CosmoKitCLI

final class OutputTests: XCTestCase {
    func testExtractFlagsFindsFlagsAnywhere() {
        XCTAssertEqual(
            CLI.extractFlags(["--json", "list", "--output", "captures", "one"]).json,
            true
        )
        XCTAssertEqual(
            CLI.extractFlags(["--json", "list", "--output", "captures", "one"]).output,
            "captures"
        )
        XCTAssertEqual(
            CLI.extractFlags(["--json", "list", "--output", "captures", "one"]).rest,
            ["list", "one"]
        )
    }

    func testExtractFlagsWithoutFlagsLeavesArgumentsUntouched() {
        let result = CLI.extractFlags(["list", "simulator"])
        XCTAssertFalse(result.json)
        XCTAssertNil(result.output)
        XCTAssertEqual(result.rest, ["list", "simulator"])
    }

    func testOutputAtEndDoesNotConsumeMissingValue() {
        let result = CLI.extractFlags(["list", "--output"])
        XCTAssertFalse(result.json)
        XCTAssertNil(result.output)
        XCTAssertEqual(result.rest, ["list", "--output"])
    }

    func testSuccessEnvelopeFlattensPayload() throws {
        let data = try encode(Envelope(ok: true, payload: VersionPayload(version: "0.1.0")))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true,\"version\":\"0.1.0\"}")
    }

    func testFailureEnvelopeUsesStableErrorCode() throws {
        let error = CommandError(code: .deviceNotFound, message: "no simulator matching \"iPhone\"")
        let data = try encode(Envelope<EmptyPayload>(ok: false, error: error))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "{\"error\":{\"code\":\"deviceNotFound\",\"message\":\"no simulator matching \\\"iPhone\\\"\"},\"ok\":false}"
        )
    }

    func testEveryErrorCodeRoundTrips() throws {
        for code in [ErrorCode.usage, .deviceNotFound, .noSimulator, .simctlFailed, .unknownCommand] {
            let data = try JSONEncoder().encode(code)
            XCTAssertEqual(try JSONDecoder().decode(ErrorCode.self, from: data), code)
        }
    }

    func testDevicePayloadReportsBootedState() throws {
        let booted = DevicePayload(udid: "1", name: "iPhone", state: "Booted", booted: true, available: true)
        let shutdown = DevicePayload(udid: "2", name: "iPad", state: "Shutdown", booted: false, available: true)
        XCTAssertEqual(String(decoding: try encode(booted), as: UTF8.self), "{\"available\":true,\"booted\":true,\"name\":\"iPhone\",\"state\":\"Booted\",\"udid\":\"1\"}")
        XCTAssertEqual(String(decoding: try encode(shutdown), as: UTF8.self), "{\"available\":true,\"booted\":false,\"name\":\"iPad\",\"state\":\"Shutdown\",\"udid\":\"2\"}")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
