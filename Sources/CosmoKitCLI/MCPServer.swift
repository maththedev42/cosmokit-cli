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
        case "list_apps":
            return ("apps", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "install_app":
            let path = try requiredString(arguments, key: "path")
            var args = [path]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("install", args, nil)
        case "uninstall_app":
            let bundleID = try requiredString(arguments, key: "bundle_id")
            var args = [bundleID]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("uninstall", args, nil)
        case "launch_app":
            let bundleID = try requiredString(arguments, key: "bundle_id")
            var args = [bundleID]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("launch", args, nil)
        case "terminate_app":
            let bundleID = try requiredString(arguments, key: "bundle_id")
            var args = [bundleID]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("terminate", args, nil)
        case "app_container":
            let bundleID = try requiredString(arguments, key: "bundle_id")
            let kind = try optionalString(arguments, key: "kind") ?? "app"
            guard ["app", "data", "groups"].contains(kind) else {
                throw usageError("argument kind must be one of: app, data, groups")
            }
            var args = [bundleID, kind]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("container", args, nil)
        case "set_appearance":
            let appearance = try optionalString(arguments, key: "appearance")
            if let appearance, !["light", "dark"].contains(appearance) { throw usageError("appearance must be one of: light, dark") }
            var args = appearance.map { [$0] } ?? []
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("appearance", args, nil)
        case "set_status_bar":
            var args: [String] = []
            let flags: [(String, String)] = [("time", "time"), ("battery_level", "batteryLevel"), ("battery_state", "batteryState"), ("wifi_bars", "wifiBars"), ("cellular_bars", "cellularBars"), ("cellular_mode", "cellularMode"), ("data_network", "dataNetwork"), ("operator_name", "operatorName")]
            for (key, flag) in flags {
                if let value = arguments[key] {
                    let rendered = ["battery_level", "wifi_bars", "cellular_bars"].contains(key)
                        ? try integerString(value, key: key, battery: key == "battery_level")
                        : try scalarString(value, key: key)
                    args += ["--\(flag)", rendered]
                }
            }
            if args.isEmpty { throw usageError("statusbar requires at least one override") }
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("statusbar", args, nil)
        case "clear_status_bar":
            return ("statusbar-clear", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "set_permission":
            let action = try requiredString(arguments, key: "action")
            let services = ["all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri"]
            guard ["grant", "revoke", "reset"].contains(action) else { throw usageError("action must be one of: grant, revoke, reset") }
            let service = try requiredString(arguments, key: "service")
            guard services.contains(service) else { throw usageError("service must be one of: \(services.joined(separator: ", "))") }
            var args = [action, service]
            if let bundle = try optionalString(arguments, key: "bundle_id") { args.append(bundle) }
            if action != "reset", arguments["bundle_id"] == nil { throw usageError("grant and revoke require a bundle id") }
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("permission", args, nil)
        case "set_biometric_enrollment":
            let enrolled = try boolString(arguments, key: "enrolled")
            var args = [enrolled == "true" ? "on" : "off"]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("biometric-enroll", args, nil)
        case "match_biometric":
            let result = try optionalString(arguments, key: "result") ?? "match"
            guard ["match", "nomatch"].contains(result) else { throw usageError("result must be one of: match, nomatch") }
            var args = [result]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("biometric-match", args, nil)
        case "send_push":
            let payloadValue = arguments["payload"] ?? NSNull()
            let payloadData: Data
            if let string = payloadValue as? String { payloadData = Data(string.utf8) }
            else { guard JSONSerialization.isValidJSONObject(payloadValue) else { throw usageError("payload must be JSON-serializable") }; payloadData = try JSONSerialization.data(withJSONObject: payloadValue, options: []) }
            let bundleID = try optionalString(arguments, key: "bundle_id")
            let validation = try CLI.validatePushPayload(payloadData, bundleID: bundleID)
            var args = [validation.bundle, "--payload", String(decoding: payloadData, as: UTF8.self)]
            if let device = try optionalString(arguments, key: "device") { args += ["--device", device] }
            return ("push", args, nil)
        case "list_location_scenarios":
            return ("scenarios", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "run_location_scenario":
            var args = [try requiredString(arguments, key: "scenario")]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("route", args, nil)
        case "clear_location":
            return ("location-clear", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "add_media":
            let paths: [String]
            if let array = arguments["paths"] as? [String] { paths = array }
            else if let string = arguments["paths"] as? String { paths = [string] }
            else { throw usageError("paths must be a string array") }
            guard !paths.isEmpty else { throw usageError("paths must not be empty") }
            var args = paths
            if let device = try optionalString(arguments, key: "device") { args += ["--device", device] }
            return ("addmedia", args, nil)
        case "get_pasteboard":
            return ("pasteboard", try optionalString(arguments, key: "device").map { [$0] } ?? [], nil)
        case "set_pasteboard":
            let text = try requiredString(arguments, key: "text")
            var args = ["--set", text]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("pasteboard", args, nil)
        case "read_defaults":
            let bundle = try requiredString(arguments, key: "bundle_id")
            let device = try optionalString(arguments, key: "device")
            return ("defaults", [bundle] + (device.map { [$0] } ?? []), nil)
        case "write_default":
            let bundle = try requiredString(arguments, key: "bundle_id")
            let key = try requiredString(arguments, key: "key")
            guard let value = arguments["value"] else { throw usageError("missing required argument: value") }
            let explicitType = try optionalString(arguments, key: "type")
            let (rendered, type) = try defaultValue(value, explicitType: explicitType)
            var args = [bundle, key, rendered, "--type", type]
            if let device = try optionalString(arguments, key: "device") { args += ["--device", device] }
            return ("defaults-write", args, nil)
        case "delete_default":
            let bundle = try requiredString(arguments, key: "bundle_id")
            let key = try requiredString(arguments, key: "key")
            var args = [bundle, key]
            if let device = try optionalString(arguments, key: "device") { args.append(device) }
            return ("defaults-delete", args, nil)
        case "get_logs":
            var args: [String] = []
            if let last = try optionalString(arguments, key: "last") { args += ["--last", try CLI.validateLogWindow(last)] }
            if let predicate = try optionalString(arguments, key: "predicate") { args += ["--predicate", predicate] }
            if let bundle = try optionalString(arguments, key: "bundle_id") { args += ["--bundle", bundle] }
            if let device = try optionalString(arguments, key: "device") { args += ["--device", device] }
            return ("logs", args, nil)
        case "list_runtimes":
            return ("runtimes", [], nil)
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

    private static func scalarString(_ value: Any, key: String) throws -> String {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber {
            return number.doubleValue.rounded() == number.doubleValue ? String(Int(number.doubleValue)) : String(describing: number.doubleValue)
        }
        throw usageError("argument \(key) must be a string or number")
    }

    private static func integerString(_ value: Any, key: String, battery: Bool) throws -> String {
        guard let number = value as? NSNumber, number.doubleValue.rounded() == number.doubleValue else {
            throw usageError("argument \(key) must be an integer")
        }
        let integer = Int(number.doubleValue)
        if battery && !(0...100).contains(integer) { throw usageError("battery_level must be between 0 and 100") }
        return String(integer)
    }

    private static func boolString(_ arguments: [String: Any], key: String) throws -> String {
        guard let value = arguments[key] else { throw usageError("missing required argument: \(key)") }
        if let value = value as? Bool { return value ? "true" : "false" }
        if let value = value as? String, ["true", "false"].contains(value.lowercased()) { return value.lowercased() }
        throw usageError("argument \(key) must be a boolean")
    }

    private static func defaultValue(_ value: Any, explicitType: String?) throws -> (String, String) {
        let allowed = ["string", "bool", "int", "float", "array", "dict"]
        let inferred: String
        let rendered: String
        if let string = value as? String { inferred = "string"; rendered = string }
        else if let bool = value as? Bool { inferred = "bool"; rendered = bool ? "true" : "false" }
        else if let number = value as? NSNumber {
            inferred = number.doubleValue.rounded() == number.doubleValue ? "int" : "float"
            rendered = inferred == "int" ? String(number.intValue) : String(describing: number.doubleValue)
        } else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: []) {
            inferred = value is [Any] ? "array" : "dict"
            rendered = String(decoding: data, as: UTF8.self)
        } else { throw usageError("argument value must be a string, number, boolean, array, or dictionary") }
        let type = explicitType ?? inferred
        guard allowed.contains(type) else { throw usageError("type must be one of: \(allowed.joined(separator: ", "))") }
        if type == "bool" {
            guard let normalized = (rendered.lowercased() == "true" || rendered == "1") ? "true" : (rendered.lowercased() == "false" || rendered == "0" ? "false" : nil) else { throw usageError("bool value must be true or false") }
            return (normalized, type)
        }
        if type == "int" {
            guard let integer = Int(rendered) else { throw usageError("int value must be an integer") }
            return (String(integer), type)
        }
        if type == "float" {
            guard let number = Double(rendered) else { throw usageError("float value must be a number") }
            return (String(describing: number), type)
        }
        return (rendered, type)
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
            tool("list_runtimes", "List installed simulator runtimes and device types; does not require a simulator.", properties: [:], required: []),
            tool("boot_simulator", "Boot a simulator by UDID, exact name, or partial name; omit device to boot the first available shutdown simulator.", properties: ["device": device], required: []),
            tool("shutdown_simulator", "Shut down a simulator by UDID, exact name, or partial name; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("erase_simulator", "Erase a simulator back to a fresh install by UDID, exact name, or partial name; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("list_apps", "List installed apps and return bundle identifiers, display names, paths, and application types; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("install_app", "Install an .app bundle on a simulator; provide its path and optionally a device, otherwise the booted simulator is used.", properties: ["path": ["type": "string", "description": "Path to the .app bundle"], "device": device], required: ["path"]),
            tool("uninstall_app", "Uninstall an app by bundle identifier; optionally provide a device, otherwise the booted simulator is used.", properties: ["bundle_id": ["type": "string", "description": "Installed app bundle identifier"], "device": device], required: ["bundle_id"]),
            tool("launch_app", "Launch an installed app by bundle identifier and return its child PID when simctl reports one; optionally provide a device.", properties: ["bundle_id": ["type": "string", "description": "Installed app bundle identifier"], "device": device], required: ["bundle_id"]),
            tool("terminate_app", "Terminate an installed app by bundle identifier; optionally provide a device, otherwise the booted simulator is used.", properties: ["bundle_id": ["type": "string", "description": "Installed app bundle identifier"], "device": device], required: ["bundle_id"]),
            tool("app_container", "Return the path to an app, data, or shared-app-groups container by bundle identifier; omit kind for the app container and omit device for the booted simulator.", properties: ["bundle_id": ["type": "string", "description": "Installed app bundle identifier"], "kind": ["type": "string", "enum": ["app", "data", "groups"], "description": "Container kind; defaults to app"], "device": device], required: ["bundle_id"]),
            tool("capture_screenshot", "Capture a PNG screenshot from a simulator; omit device to use the booted simulator and output to use the current directory.", properties: ["device": device, "output": ["type": "string", "description": "Directory where the timestamped PNG should be written"]], required: []),
            tool("record_video", "Record simulator video for a fixed number of seconds; omit device to use the booted simulator and output to use the current directory.", properties: ["device": device, "output": ["type": "string", "description": "Directory where the timestamped MP4 should be written"], "duration": ["type": "number", "description": "Number of seconds to record"]], required: ["duration"]),
            tool("set_appearance", "Set or read a simulator's light or dark appearance; omit appearance to read the current value and omit device to use the booted simulator.", properties: ["appearance": ["type": "string", "enum": ["light", "dark"]], "device": device], required: []),
            tool("set_status_bar", "Override simulator status bar values for a screenshot; provide at least one override and omit device to use the booted simulator.", properties: ["time": ["type": "string"], "battery_level": ["type": "number"], "battery_state": ["type": "string"], "wifi_bars": ["type": "number"], "cellular_bars": ["type": "number"], "cellular_mode": ["type": "string"], "data_network": ["type": "string"], "operator_name": ["type": "string"], "device": device], required: []),
            tool("clear_status_bar", "Clear all simulator status bar overrides; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("set_permission", "Grant, revoke, or reset a simulator privacy permission; some changes terminate the running app, and omit device to use the booted simulator.", properties: ["action": ["type": "string", "enum": ["grant", "revoke", "reset"]], "service": ["type": "string", "enum": ["all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri"]], "bundle_id": ["type": "string"], "device": device], required: ["action", "service"]),
            tool("set_biometric_enrollment", "Set biometric enrollment on or off; enrollment must be on before a biometric match can affect an app prompt, and omit device to use the booted simulator.", properties: ["enrolled": ["type": "boolean"], "device": device], required: ["enrolled"]),
            tool("match_biometric", "Post a Face ID or Touch ID match result while an app is showing its biometric prompt; enrollment must be on first, and omit device to use the booted simulator.", properties: ["result": ["type": "string", "enum": ["match", "nomatch"]], "device": device], required: []),
            tool("open_url", "Open a deep link or URL in a simulator; omit device to use the booted simulator.", properties: ["device": device, "url": ["type": "string", "description": "URL or deep link to open"]], required: ["url"]),
            tool("send_push", "Send a validated APNs push payload to an app; payload must be a JSON object with aps and may include Simulator Target Bundle, otherwise provide bundle_id.", properties: ["payload": ["type": "object", "description": "JSON push payload containing aps"], "bundle_id": ["type": "string"], "device": device], required: ["payload"]),
            tool("add_media", "Add one or more photo or video files to a simulator's library; omit device to use the booted simulator.", properties: ["paths": ["type": "array", "items": ["type": "string"]], "device": device], required: ["paths"]),
            tool("get_pasteboard", "Read the simulator pasteboard as text; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("set_pasteboard", "Set simulator pasteboard text, replacing its current contents; omit device to use the booted simulator.", properties: ["text": ["type": "string"], "device": device], required: ["text"]),
            tool("set_location", "Set a simulator's GPS location using latitude and longitude; omit device to use the booted simulator.", properties: ["device": device, "latitude": ["type": "number", "description": "Latitude in decimal degrees"], "longitude": ["type": "number", "description": "Longitude in decimal degrees"]], required: ["latitude", "longitude"]),
            tool("list_location_scenarios", "List built-in simulated location scenarios; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("run_location_scenario", "Run a simulated location route until clear_location is called; unlike set_location this keeps moving, and omit device to use the booted simulator.", properties: ["scenario": ["type": "string", "description": "Scenario name, preserving spaces"], "device": device], required: ["scenario"]),
            tool("clear_location", "Stop a running location scenario and clear the fixed location; omit device to use the booted simulator.", properties: ["device": device], required: []),
            tool("read_defaults", "Read an app's UserDefaults by resolving its data container path; an empty result means the app has not written defaults yet.", properties: ["bundle_id": ["type": "string"], "device": device], required: ["bundle_id"]),
            tool("write_default", "Write an app UserDefaults value. Restart the app for the changed default to take effect.", properties: ["bundle_id": ["type": "string"], "key": ["type": "string"], "value": ["type": ["string", "number", "boolean", "array", "object"], "description": "String, number, boolean, array, or dictionary"], "type": ["type": "string", "enum": ["string", "bool", "int", "float", "array", "dict"]], "device": device], required: ["bundle_id", "key", "value"]),
            tool("delete_default", "Delete an app UserDefaults value. Restart the app for the change to take effect.", properties: ["bundle_id": ["type": "string"], "key": ["type": "string"], "device": device], required: ["bundle_id", "key"]),
            tool("get_logs", "Read the last bounded simulator log window, keeping at most the last 500 lines.", properties: ["last": ["type": "string", "description": "30s, 5m, or 1h; defaults to 1m"], "predicate": ["type": "string"], "bundle_id": ["type": "string", "description": "Convenience subsystem predicate when predicate is omitted"], "device": device], required: [])
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
