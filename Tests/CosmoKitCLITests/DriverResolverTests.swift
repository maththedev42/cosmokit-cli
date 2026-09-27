import XCTest
@testable import CosmoKitCLI

final class DriverResolverTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("driver-resolver-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func createProject(at dir: URL) throws {
        let proj = dir.appendingPathComponent("CosmoKitAgentDriver.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    }

    func testCOSMOKIT_DRIVER_DIR_takesPrecedence() throws {
        let envDir = tempDirectory.appendingPathComponent("custom-env-driver")
        try createProject(at: envDir)

        let binDir = tempDirectory.appendingPathComponent("bin")
        let shareDriver = tempDirectory.appendingPathComponent("share/cosmokit/Driver")
        try createProject(at: shareDriver)

        let cwd = tempDirectory.appendingPathComponent("cwd")
        let cwdDriver = cwd.appendingPathComponent("Driver")
        try createProject(at: cwdDriver)

        let resolved = try Driver.driverSourceRoot(
            environment: ["COSMOKIT_DRIVER_DIR": envDir.path],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, envDir.standardizedFileURL.path)
    }

    func testShareCosmoKitDriverLayout() throws {
        let binDir = tempDirectory.appendingPathComponent("bin")
        let shareDriver = tempDirectory.appendingPathComponent("share/cosmokit/Driver")
        try createProject(at: shareDriver)

        let cwd = tempDirectory.appendingPathComponent("cwd")
        let cwdDriver = cwd.appendingPathComponent("Driver")
        try createProject(at: cwdDriver)

        let resolved = try Driver.driverSourceRoot(
            environment: [:],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, shareDriver.standardizedFileURL.path)
    }

    func testCwdDriverLayout() throws {
        let binDir = tempDirectory.appendingPathComponent("bin")
        let cwd = tempDirectory.appendingPathComponent("cwd")
        let cwdDriver = cwd.appendingPathComponent("Driver")
        try createProject(at: cwdDriver)

        let resolved = try Driver.driverSourceRoot(
            environment: [:],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, cwdDriver.standardizedFileURL.path)
    }

    func testCwdCliDriverLayout() throws {
        let binDir = tempDirectory.appendingPathComponent("bin")
        let cwd = tempDirectory.appendingPathComponent("cwd")
        let cliDriver = cwd.appendingPathComponent("cli/Driver")
        try createProject(at: cliDriver)

        let resolved = try Driver.driverSourceRoot(
            environment: [:],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, cliDriver.standardizedFileURL.path)
    }

    func testDriverNotFoundThrowsErrorWithAllCheckedPaths() {
        let binDir = tempDirectory.appendingPathComponent("bin")
        let cwd = tempDirectory.appendingPathComponent("cwd")

        XCTAssertThrowsError(try Driver.driverSourceRoot(
            environment: ["COSMOKIT_DRIVER_DIR": "/nonexistent/custom/driver"],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )) { error in
            guard let cliError = error as? CLIError else {
                XCTFail("Expected CLIError, got \(error)")
                return
            }
            XCTAssertEqual(cliError.commandError.code, .driverUnavailable)
            let msg = cliError.commandError.message
            XCTAssertTrue(msg.contains("driver sources not found"), "Expected message to mention not found: \(msg)")
            XCTAssertTrue(msg.contains("/nonexistent/custom/driver"), "Expected message to mention env path: \(msg)")
            XCTAssertTrue(msg.contains("share/cosmokit/Driver"), "Expected message to mention share path: \(msg)")
            XCTAssertTrue(msg.contains("cwd/Driver"), "Expected message to mention cwd/Driver path: \(msg)")
            XCTAssertTrue(msg.contains("cwd/cli/Driver"), "Expected message to mention cwd/cli/Driver path: \(msg)")
            XCTAssertTrue(msg.contains("reinstall cosmokit, or set COSMOKIT_DRIVER_DIR to a checkout's cli/Driver"), "Expected recovery hint: \(msg)")
        }
    }

    func testDoctorIncludesDriverSourcesCheck() throws {
        let binDir = tempDirectory.appendingPathComponent("bin")
        let shareDriver = tempDirectory.appendingPathComponent("share/cosmokit/Driver")
        try createProject(at: shareDriver)
        let cwd = tempDirectory.appendingPathComponent("cwd")

        let result = Doctor.run(
            environment: [:],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )

        let check = result.checks.first { $0.name == "driver sources" }
        XCTAssertNotNil(check, "Expected 'driver sources' check in doctor result")
        XCTAssertEqual(check?.ok, true)
        XCTAssertEqual(check?.detail, shareDriver.standardizedFileURL.path)
    }

    func testDoctorReportsMissingDriverSourcesWhenNotFound() {
        let binDir = tempDirectory.appendingPathComponent("bin")
        let cwd = tempDirectory.appendingPathComponent("cwd")

        let result = Doctor.run(
            environment: [:],
            executableURL: binDir.appendingPathComponent("cosmokit"),
            currentDirectory: cwd
        )

        let check = result.checks.first { $0.name == "driver sources" }
        XCTAssertNotNil(check, "Expected 'driver sources' check in doctor result")
        XCTAssertEqual(check?.ok, false)
        XCTAssertEqual(check?.detail, "missing")
        XCTAssertTrue(check?.hint?.contains("COSMOKIT_DRIVER_DIR") == true)
    }
}
