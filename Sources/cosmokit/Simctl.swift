//
//  Simctl.swift
//  cosmokit CLI
//
//  Thin wrapper over `xcrun simctl`. Deliberately standalone rather than
//  sharing code with the app target: the CLI has to build and run without
//  Xcode's app scheme, and the surface it needs is small.
//

import Foundation

struct SimctlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Device: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool

    var isBooted: Bool { state == "Booted" }
}

enum Simctl {

    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
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
            throw SimctlError(message: "could not run xcrun: \(error.localizedDescription)")
        }

        // Read before waiting: a large `list` output fills the pipe buffer and
        // deadlocks if we wait for exit first.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw SimctlError(message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Every simulator, newest runtimes first as simctl reports them.
    static func devices() throws -> [Device] {
        let json = try run(["list", "devices", "--json"])
        guard let data = json.data(using: .utf8) else { return [] }

        struct Payload: Decodable { let devices: [String: [Device]] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.devices.values.flatMap { $0 }
    }

    /// Resolves a user-supplied name, UDID or the special value "booted".
    static func resolveDevice(_ query: String?) throws -> Device {
        let all = try devices().filter { $0.isAvailable }
        guard let query, query.lowercased() != "booted" else {
            guard let booted = all.first(where: { $0.isBooted }) else {
                throw SimctlError(message: "no booted simulator (pass a name or UDID, or run `cosmokit boot`)")
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
        throw SimctlError(message: "no simulator matching \"\(query)\"")
    }
}
