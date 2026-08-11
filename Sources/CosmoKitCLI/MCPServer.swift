//
//  MCPServer.swift
//  cosmokit CLI
//
//  Minimal newline-delimited JSON-RPC transport for agent clients.
//

import Foundation

public enum MCPServer {
    /// How a tool call reaches the simulator. Tests substitute a stub so the
    /// mapping can be proven without a simulator.
    public static var execute: (_ command: String, _ args: [String], _ output: String?) throws -> CommandOutcome = {
        try CLI.perform(command: $0, args: $1, output: $2)
    }

    public static func commandInvocation(tool: String, arguments: [String: Any]) throws -> (command: String, args: [String], output: String?) {
        switch tool {
        case "list_simulators":
            return ("list", [], nil)
        case "boot_simulator":
            return ("boot", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "shutdown_simulator":
            return ("shutdown", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "erase_simulator":
            return ("erase", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "capture_screenshot":
            return ("capture", try optionalString(arguments, key: "device").map { [$0] } ?? [], try optionalString(arguments, key: "output"))
        case "record_video":
            let duration = try requiredDuration(arguments, key: "duration")
            var args = try optionalString(arguments, key: "device").map { [$0] } ?? []
            args += ["--duration", duration]
            return ("record", args, try optionalString(arguments, key: "output"))
        case "set_location":
            let latitude = try requiredCoordinate(arguments, key: "latitude")
            let longitude = try requiredCoordinate(arguments, key: "longitude")
            var args = [latitude, longitude]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("location", args, nil)
        case "open_url":
            let url = try requiredString(arguments, key: "url")
            var args = [url]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("open", args, nil)
        default:
            throw CLIError(commandError: CommandError(code: .unknownCommand, message: "Unknown tool: \(tool)"))
        }
    }

    /// Handles one JSON-RPC message. Notifications receive no response.
    public static func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return response(id: NSNull(), error: [-32700, "Parse error"])
        }
        guard let request = object as? [String: Any] else {
            return response(id: NSNull(), error: [-32600, "Invalid Request"])
        }

        guard let method = request["method"] as? String else {
            return response(id: request["id"] ?? NSNull(), error: [-32600, "Invalid Request"])
        }

        guard request["id"] != nil else {
            return nil
        }

        switch method {
        case "initialize":
            guard request["params"] == nil || request["params"] is [String: Any] else {
                return response(id: request["id"] ?? NSNull(), error: [-32602, "Invalid params"])
            }
            let params = request["params"] as? [String: Any]
            let requestedVersion = params?["protocolVersion"] as? String
            let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let protocolVersion = supportedVersions.contains(requestedVersion ?? "") ? requestedVersion! : "2025-06-18"
            return response(id: request["id"] ?? NSNull(), result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "cosmokit", "version": CLI.version]
            ])

        case "tools/list":
            guard request["params"] == nil || request["params"] is [String: Any] else {
                return response(id: request["id"] ?? NSNull(), error: [-32602, "Invalid params"])
            }
            return response(id: request["id"] ?? NSNull(), result: ["tools": tools()])

        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String, !name.isEmpty else {
                return response(id: request["id"] ?? NSNull(), error: [-32602, "Invalid params: name is required"])
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return response(id: request["id"] ?? NSNull(), error: [-32602, "Invalid params: arguments must be an object"])
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let invocation = try commandInvocation(tool: name, arguments: arguments)
                let outcome = try execute(invocation.command, invocation.args, invocation.output)
                let text = try String(decoding: outcome.jsonData(), as: UTF8.self)
                return response(id: request["id"] ?? NSNull(), result: [
                    "content": [["type": "text", "text": text]]
                ])
            } catch {
                let text = failureText(for: error)
                return response(id: request["id"] ?? NSNull(), result: [
                    "content": [["type": "text", "text": text]],
                    "isError": true
                ])
            }

        default:
            return response(id: request["id"] ?? NSNull(), error: [-32601, "Method not found"])
        }
    }

    /// Reads newline-delimited requests until stdin reaches EOF.
    public static func serve() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let result = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((result + "\n").utf8))
            try? FileHandle.standardOutput.synchronize()
        }
    }

    private static func response(id: Any, result: Any? = nil, error: [Any]? = nil) -> String {
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let result {
            response["result"] = result
        } else if let error {
            response["error"] = ["code": error[0], "message": error[1]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func usageError(_ message: String) -> CLIError {
        CLIError(commandError: CommandError(code: .usage, message: message))
    }

    private static func requiredString(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = arguments[key] else { throw usageError("missing required argument: \(key)") }
        guard let string = value as? String, !string.isEmpty else { throw usageError("argument \(key) must be a non-empty string") }
        return string
    }

    private static func optionalString(_ arguments: [String: Any], key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String, !string.isEmpty else { throw usageError("argument \(key) must be a non-empty string") }
        return string
    }

    private static func requiredCoordinate(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = arguments[key] else { throw usageError("missing required argument: \(key)") }
        let number: Double?
        if let string = value as? String {
            number = Double(string)
        } else if let numberValue = value as? NSNumber {
            number = numberValue.doubleValue
        } else {
            number = nil
        }
        guard let number else { throw usageError("argument \(key) must be a number") }
        return String(describing: number)
    }

    private static func requiredDuration(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = arguments[key] else { throw usageError("missing required argument: \(key)") }
        let number: Double?
        if let numberValue = value as? NSNumber {
            number = numberValue.doubleValue
        } else if let string = value as? String {
            number = Double(string)
        } else {
            number = nil
        }
        guard let number, number > 0 else { throw usageError("argument \(key) must be a positive number") }
        return number.rounded() == number ? String(Int(number)) : String(describing: number)
    }

    private static func failureText(for error: Error) -> String {
        let commandError: CommandError
        if let cliError = error as? CLIError {
            commandError = cliError.commandError
        } else {
            commandError = CommandError(code: .simctlFailed, message: error.localizedDescription)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(Envelope<EmptyPayload>(ok: false, error: commandError)), as: UTF8.self)
        } catch {
            return "{\"error\":{\"code\":\"simctlFailed\",\"message\":\"could not encode failure\"},\"ok\":false}"
        }
    }

    private static func tools() -> [[String: Any]] {
        let device = [
            "type": "string",
            "description": "UDID, exact name, or partial name; omit to use the booted simulator"
        ]
        return [
            tool("list_simulators", "List available iOS Simulators, sorted by name. Takes no arguments.", properties: [:], required: []),
            tool("boot_simulator", "Boot a simulator by UDID, exact name, or partial name; omit device to boot the first available shutdown simulator.", properties: ["device": device], required: []),
            tool("shutdown_simulator", "Shut down a simulator by UDID, exact name, or partial name; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("capture_screenshot", "Capture a PNG screenshot from a simulator; omit device to use the booted simulator and output to use the current directory.", properties: ["device": device, "output": ["type": "string", "description": "Directory where the timestamped PNG should be written"]], required: []),
            tool("record_video", "Record simulator video for a fixed number of seconds; omit device to use the booted simulator and output to use the current directory.", properties: ["device": device, "output": ["type": "string", "description": "Directory where the timestamped MP4 should be written"], "duration": ["type": "number", "description": "Number of seconds to record"]], required: ["duration"]),
            tool("set_location", "Set a simulator's GPS location using latitude and longitude; omit device to use the booted simulator.", properties: ["device": device, "latitude": ["type": "number", "description": "Latitude in decimal degrees"], "longitude": ["type": "number", "description": "Longitude in decimal degrees"]], required: ["latitude", "longitude"]),
            tool("open_url", "Open a deep link or URL in a simulator; omit device to use the booted simulator.", properties: ["device": device, "url": ["type": "string", "description": "URL or deep link to open"]], required: ["url"]),
            tool("erase_simulator", "Erase a simulator back to a fresh install by UDID, exact name, or partial name; omit device to use the booted simulator.", properties: ["device": device], required: [])
        ]
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ]
        ]
    }
}
