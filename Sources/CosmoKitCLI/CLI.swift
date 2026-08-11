//
//  main.swift
//  cosmokit CLI
//
//  Scriptable access to the same simulator operations the app performs, for
//  Makefiles, git hooks and CI. Once a team has `cosmokit capture` in a
//  script, the tool is part of the workflow rather than something they
//  remember to open.
//

import Foundation

/// What a command produced. `human` is the exact line the CLI has always
/// printed; `json` is the same result as an encodable payload.
public struct CommandOutcome {
    public let human: String
    public let jsonData: () throws -> Data

    public init<Payload: Encodable>(human: String, json: Payload) {
        self.human = human
        self.jsonData = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(Envelope(ok: true, payload: json))
        }
    }
}

public struct CLIError: LocalizedError {
    public let commandError: CommandError

    public var errorDescription: String? { commandError.message }

    public init(commandError: CommandError) {
        self.commandError = commandError
    }
}

public enum CLI {
    public static let version = "0.1.0"

    static func printUsage() {
        print("""
        cosmokit \(CLI.version) — drive the iOS Simulator from the command line

        USAGE
          cosmokit <command> [options]

        COMMANDS
          list                        List available simulators
          boot [name|udid]            Boot a simulator (default: first available)
          shutdown [name|udid]        Shut a simulator down (default: booted)
          capture [name|udid]         Screenshot to a file
          record [name|udid]          Record video until you press Ctrl-C
          location <lat> <lon> [dev]  Set the simulator's GPS position
          open <url> [name|udid]      Open a deep link
          erase [name|udid]           Erase a simulator back to a fresh install
          mcp                         Run as an MCP server over stdio (for AI agents)
          help                        Show this message

        OPTIONS
          --output <path>             Where to write a capture (default: ./)
          --json                      Emit machine-readable JSON on stdout
          --duration <seconds>        Recording duration (for record)

        EXAMPLES
          cosmokit capture --output ./screenshots
          cosmokit location -22.9068 -43.1729
          cosmokit open "myapp://item/42"
          cosmokit --json list
        """)
    }

/// Pulls output-related flags out of the argument list, returning the rest.
    public static func extractFlags(_ args: [String]) -> (json: Bool, output: String?, duration: String?, rest: [String]) {
        var json = false
        var output: String?
        var duration: String?
        var rest: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
                index += 1
                continue
            case "--output" where index + 1 < args.count:
                output = args[index + 1]
                index += 2
                continue
            case "--duration":
                duration = index + 1 < args.count ? args[index + 1] : ""
                index += index + 1 < args.count ? 2 : 1
                continue
            default:
                break
            }
            rest.append(args[index])
            index += 1
        }
        return (json, output, duration, rest)
    }

    public static func extractOutput(_ args: [String]) -> (output: String?, rest: [String]) {
        let flags = extractFlags(args)
        return (flags.output, flags.rest)
    }

    public static func timestampedPath(directory: String?, prefix: String, ext: String, deviceName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safeName = deviceName.replacingOccurrences(of: " ", with: "-")
        let filename = "\(prefix)-\(safeName)-\(formatter.string(from: Date())).\(ext)"
        let base = directory ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: base).appendingPathComponent(filename).path
    }

    public static func run(_ rawArgs: [String]) {
        let flags = extractFlags(rawArgs)
        guard let command = flags.rest.first else {
            printUsage()
            exit(0)
        }

        do {
            if command == "mcp" {
                MCPServer.serve()
                return
            }
            let outcome = try perform(
                command: command,
                args: Array(flags.rest.dropFirst()),
                output: flags.output,
                duration: try parseDuration(flags.duration)
            )
            if flags.json {
                writeJSONData(try outcome.jsonData())
            } else {
                print(outcome.human)
            }
        } catch {
            if flags.json {
                let commandError = (error as? CLIError)?.commandError
                    ?? CommandError(code: errorCode(for: error), message: error.localizedDescription)
                writeFailure(commandError)
            }
            if let commandError = (error as? CLIError)?.commandError,
               commandError.code == .unknownCommand, !flags.json {
                FileHandle.standardError.write(Data("Unknown command: \(commandError.message.replacingOccurrences(of: "Unknown command: ", with: ""))\n\n".utf8))
                printUsage()
            } else {
                FileHandle.standardError.write(Data("cosmokit: \(error.localizedDescription)\n".utf8))
            }
            exit(1)
        }
    }

    public static func perform(command: String, args: [String], output: String?) throws -> CommandOutcome {
        try perform(command: command, args: args, output: output, duration: nil)
    }

    public static func perform(command: String, args: [String], output: String?, duration: Double?) throws -> CommandOutcome {
        switch command {
        case "help", "--help", "-h":
            return CommandOutcome(human: usageText(), json: EmptyPayload())

        case "version", "--version":
            return CommandOutcome(human: CLI.version, json: VersionPayload(version: CLI.version))

        case "list":
            let devices = try devices()
                .filter { $0.isAvailable }
                .sorted { $0.name < $1.name }
            let human = devices.isEmpty
                ? "No available simulators."
                : devices.map { "\($0.isBooted ? "●" : "○") \($0.name)  \($0.udid)  \($0.state)" }.joined(separator: "\n")
            let payload = devices.map {
                DevicePayload(udid: $0.udid, name: $0.name, state: $0.state, booted: $0.isBooted, available: $0.isAvailable)
            }
            return CommandOutcome(human: human, json: DevicesPayload(devices: payload))

        case "boot":
            let device: Device
            if let query = args.first {
                device = try resolveDevice(query)
            } else if let firstShutdown = try devices().first(where: { $0.isAvailable && !$0.isBooted }) {
                device = firstShutdown
            } else {
                throw CLIError(commandError: CommandError(code: .noSimulator, message: "no available simulator to boot"))
            }
            let alreadyBooted = device.isBooted
            if !alreadyBooted {
                try runSimctl(["boot", device.udid])
            }
            return CommandOutcome(
                human: alreadyBooted ? "Already booted: \(device.name)" : "Booted \(device.name)",
                json: BootPayload(udid: device.udid, name: device.name, alreadyBooted: alreadyBooted)
            )

        case "shutdown":
            let device = try resolveDevice(args.first)
            try runSimctl(["shutdown", device.udid])
            return CommandOutcome(human: "Shut down \(device.name)", json: ShutdownPayload(udid: device.udid, name: device.name))

        case "capture":
            let device = try resolveDevice(args.first)
            let path = timestampedPath(directory: output, prefix: "CosmoKit-Screenshot", ext: "png", deviceName: device.name)
            try runSimctl(["io", device.udid, "screenshot", path])
            return CommandOutcome(human: path, json: CapturePayload(udid: device.udid, name: device.name, path: path))

        case "record":
            let device = try resolveDevice(args.first)
            let path = timestampedPath(directory: output, prefix: "CosmoKit-Recording", ext: "mp4", deviceName: device.name)
            let human = "Recording \(device.name). Press Ctrl-C to stop.\n\(path)"
            try Simctl.runInterruptible(["io", device.udid, "recordVideo", path], stopAfter: duration)
            return CommandOutcome(human: human, json: RecordPayload(udid: device.udid, name: device.name, path: path))

        case "location":
            let location = try parseLocation(args)
            let device = try resolveDevice(location.query)
            try runSimctl(["location", device.udid, "set", "\(location.latitude),\(location.longitude)"])
            return CommandOutcome(human: "Set \(device.name) to \(location.latitude), \(location.longitude)", json: LocationPayload(udid: device.udid, name: device.name, latitude: location.latitude, longitude: location.longitude))

        case "open":
            guard let url = args.first else {
                throw CLIError(commandError: CommandError(code: .usage, message: "usage: cosmokit open <url> [name|udid]"))
            }
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            try runSimctl(["openurl", device.udid, url])
            return CommandOutcome(human: "Opened \(url) on \(device.name)", json: OpenPayload(udid: device.udid, name: device.name, url: url))

        case "erase":
            let device = try resolveDevice(args.first)
            _ = try? runSimctl(["shutdown", device.udid])
            try runSimctl(["erase", device.udid])
            return CommandOutcome(human: "Erased \(device.name)", json: ErasePayload(udid: device.udid, name: device.name))

        default:
            throw CLIError(commandError: CommandError(code: .unknownCommand, message: "Unknown command: \(command)"))
        }
    }

    public static func parseLocation(_ args: [String]) throws -> (latitude: Double, longitude: Double, query: String?) {
        guard args.count >= 2, let latitude = Double(args[0]), let longitude = Double(args[1]) else {
            throw CLIError(commandError: CommandError(code: .usage, message: "usage: cosmokit location <lat> <lon> [name|udid]"))
        }
        return (latitude, longitude, args.count > 2 ? args[2] : nil)
    }

    public static func parseDuration(_ raw: String?) throws -> Double? {
        guard let raw else { return nil }
        guard let duration = Double(raw), duration > 0 else {
            throw CLIError(commandError: CommandError(code: .usage, message: "usage: cosmokit record --duration <seconds>"))
        }
        return duration
    }

    private static func resolveDevice(_ query: String?) throws -> Device {
        do {
            return try Simctl.resolveDevice(query)
        } catch {
            throw CLIError(commandError: CommandError(code: errorCode(for: error), message: error.localizedDescription))
        }
    }

    private static func devices() throws -> [Device] {
        do {
            return try Simctl.devices()
        } catch {
            throw CLIError(commandError: CommandError(code: .simctlFailed, message: error.localizedDescription))
        }
    }

    @discardableResult
    private static func runSimctl(_ arguments: [String]) throws -> String {
        do {
            return try Simctl.run(arguments)
        } catch {
            throw CLIError(commandError: CommandError(code: .simctlFailed, message: error.localizedDescription))
        }
    }

    private static func usageText() -> String {
        """
        cosmokit \(CLI.version) — drive the iOS Simulator from the command line

        USAGE
          cosmokit <command> [options]

        COMMANDS
          list                        List available simulators
          boot [name|udid]            Boot a simulator (default: first available)
          shutdown [name|udid]        Shut a simulator down (default: booted)
          capture [name|udid]         Screenshot to a file
          record [name|udid]          Record video until you press Ctrl-C
          location <lat> <lon> [dev]  Set the simulator's GPS position
          open <url> [name|udid]      Open a deep link
          erase [name|udid]           Erase a simulator back to a fresh install
          mcp                         Run as an MCP server over stdio (for AI agents)
          help                        Show this message

        OPTIONS
          --output <path>             Where to write a capture (default: ./)
          --json                      Emit machine-readable JSON on stdout
          --duration <seconds>        Recording duration (for record)

        EXAMPLES
          cosmokit capture --output ./screenshots
          cosmokit location -22.9068 -43.1729
          cosmokit open "myapp://item/42"
          cosmokit --json list
        """
    }

    private static func writeJSON<Payload: Encodable>(_ envelope: Envelope<Payload>) {
        do {
            writeJSONData(try encodeJSON(envelope))
        } catch {
            FileHandle.standardError.write(Data("cosmokit: could not encode JSON: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func encodeJSON<Payload: Encodable>(_ envelope: Envelope<Payload>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private static func writeJSONData(_ data: Data) {
        print(String(decoding: data, as: UTF8.self))
    }

    private static func writeFailure(_ error: CommandError) {
        writeJSON(Envelope<EmptyPayload>(ok: false, error: error))
    }

    public static func errorCode(for error: Error) -> ErrorCode {
        if let commandError = error as? CLIError {
            return commandError.commandError.code
        }
        if let simctlError = error as? SimctlError {
            switch simctlError.kind {
            case .noBootedDevice:
                return .noSimulator
            case .noMatch:
                return .deviceNotFound
            case .commandFailed, .launchFailed:
                return .simctlFailed
            }
        }
        return .simctlFailed
    }
}

public struct VersionPayload: Encodable {
    public let version: String
    public init(version: String) { self.version = version }
}

public struct DevicePayload: Encodable {
    public let udid: String
    public let name: String
    public let state: String
    public let booted: Bool
    public let available: Bool

    public init(udid: String, name: String, state: String, booted: Bool, available: Bool) {
        self.udid = udid
        self.name = name
        self.state = state
        self.booted = booted
        self.available = available
    }
}

public struct DevicesPayload: Encodable {
    public let devices: [DevicePayload]
    public init(devices: [DevicePayload]) { self.devices = devices }
}
