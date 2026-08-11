import XCTest
@testable import CosmoKitCLI

final class ErrorMappingTests: XCTestCase {
    func testLocationUsageErrors() {
        assertCode { try CLI.perform(command: "location", args: ["-22.9068"], output: nil) }
        assertCode { try CLI.perform(command: "location", args: ["north", "west"], output: nil) }
    }

    func testLocationParsesNegativeFractionalCoordinatesAndDevice() throws {
        let result = try CLI.parseLocation(["-22.9068", "-43.1729", "iPhone 16"])
        XCTAssertEqual(result.latitude, -22.9068)
        XCTAssertEqual(result.longitude, -43.1729)
        XCTAssertEqual(result.query, "iPhone 16")
    }

    func testOpenWithoutURLIsUsage() {
        assertCode { try CLI.perform(command: "open", args: [], output: nil) }
    }

    func testDurationParsing() throws {
        XCTAssertEqual(try CLI.parseDuration("1.25"), 1.25)
        XCTAssertNil(try CLI.parseDuration(nil))
        assertCode { try CLI.parseDuration("0") }
        assertCode { try CLI.parseDuration("-1") }
        assertCode { try CLI.parseDuration("soon") }
    }

    func testUnknownCommandIsStable() {
        assertCode({ try CLI.perform(command: "dance", args: [], output: nil) }, code: .unknownCommand)
    }

    func testSimctlKindsDetermineCodesNotMessages() {
        XCTAssertEqual(CLI.errorCode(for: SimctlError(kind: .noBootedDevice, message: "xyzzy")), .noSimulator)
        XCTAssertEqual(CLI.errorCode(for: SimctlError(kind: .noMatch, message: "xyzzy")), .deviceNotFound)
        XCTAssertEqual(CLI.errorCode(for: SimctlError(kind: .commandFailed, message: "xyzzy")), .simctlFailed)
        XCTAssertEqual(CLI.errorCode(for: SimctlError(kind: .launchFailed, message: "xyzzy")), .simctlFailed)
    }

    private func assertCode(
        _ expression: () throws -> Any,
        code expected: ErrorCode = .usage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let cliError = error as? CLIError else {
                return XCTFail("expected CLIError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(cliError.commandError.code, expected, file: file, line: line)
        }
    }
}
