//
//  Simctl.swift
//  cosmokit CLI
//
//  Thin wrapper over `xcrun simctl`. Deliberately standalone rather than
//  sharing code with the app target: the CLI has to build and run without
//  Xcode's app scheme, and the surface it needs is small.
//

import Foundation

public struct SimctlError: LocalizedError {
    public enum Kind: Equatable {
        case noBootedDevice
        case noMatch
        case commandFailed
        case launchFailed
    }

    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct Device: Decodable {
    public let udid: String
    public let name: String
    public let state: String
    public let isAvailable: Bool

    public var isBooted: Bool { state == "Booted" }

    public init(udid: String, name: String, state: String, isAvailable: Bool) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
    }
}

public enum Simctl {

    @discardableResult
    public static func run(_ arguments: [String], input: Data?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        do { try process.run() } catch {
            throw SimctlError(kind: .launchFailed, message: "could not run xcrun: \(error.localizedDescription)")
        }
        if let input { stdin.fileHandleForWriting.write(input) }
        stdin.fileHandleForWriting.closeFile()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw SimctlError(kind: .commandFailed, message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    @discardableResult
    public static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SimctlError(kind: .launchFailed, message: "could not run xcrun: \(error.localizedDescription)")
        }

        // Read before waiting: a large `list` output fills the pipe buffer and
        // deadlocks if we wait for exit first.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw SimctlError(kind: .commandFailed, message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    @discardableResult
    public static func runInterruptible(_ arguments: [String], stopAfter seconds: Double?) throws -> String {
        guard let seconds else {
            return try run(arguments)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SimctlError(kind: .launchFailed, message: "could not run xcrun: \(error.localizedDescription)")
        }

        Thread.sleep(forTimeInterval: seconds)
        process.interrupt()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw SimctlError(kind: .commandFailed, message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Every simulator, newest runtimes first as simctl reports them.
    public static func devices() throws -> [Device] {
        let json = try run(["list", "devices", "--json"])
        guard let data = json.data(using: .utf8) else { return [] }

        struct Payload: Decodable { let devices: [String: [Device]] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.devices.values.flatMap { $0 }
    }

    /// Resolves a user-supplied name, UDID or the special value "booted".
    public static func resolveDevice(_ query: String?) throws -> Device {
        let all = try devices().filter { $0.isAvailable }
        guard let query, query.lowercased() != "booted" else {
            guard let booted = all.first(where: { $0.isBooted }) else {
                throw SimctlError(kind: .noBootedDevice, message: "no booted simulator (pass a name or UDID, or run `cosmokit boot`)")
            }
            return booted
        }
        if let exact = all.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact
        }
        if let named = all.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return named
        }
        if let partial = all.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) {
            return partial
        }
        throw SimctlError(kind: .noMatch, message: "no simulator matching \"\(query)\"")
    }
}
