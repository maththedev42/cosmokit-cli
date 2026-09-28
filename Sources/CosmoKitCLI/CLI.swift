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
import SystemConfiguration
import Darwin

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
    public static let version = "0.4.1"
    public static var runSimctlForTesting: (_ arguments: [String]) throws -> String = { try Simctl.run($0) }
    public static var runSimctlTimedForTesting: (_ arguments: [String], _ timeout: TimeInterval) throws -> String = { try Simctl.run($0, timeout: $1) }
    public static var proxySourceForTesting: () -> [String: Any]? = { SCDynamicStoreCopyProxies(nil) as? [String: Any] }
    public static var resolveDeviceForTesting: (_ query: String?) throws -> Device = { try Simctl.resolveDevice($0) }

    static func printUsage() {
        print("""
        cosmokit \(CLI.version) — drive the iOS Simulator from the command line

        USAGE
          cosmokit <command> [options]

        COMMANDS
          DISCOVERY
          list                        List available simulators
          runtimes                    List runtimes and device types
          LIFECYCLE
          boot [name|udid]            Boot a simulator (default: first available)
          shutdown [name|udid]        Shut a simulator down (default: booted)
          erase [name|udid]           Erase a simulator back to a fresh install
          APPS
          apps [name|udid]            List installed apps
          install <path> [name|udid]  Install an app bundle
          uninstall <bundle> [name|udid] Uninstall an app
          launch <bundle> [name|udid] Launch an app
          terminate <bundle> [name|udid] Terminate an app
          container <bundle> [kind] [name|udid] Get an app container path
          CAPTURE
          capture [name|udid]         Screenshot to a file
          record [name|udid]          Record video until you press Ctrl-C
          STATE
          appearance [light|dark] [name|udid] Set or read appearance
          statusbar [flags] [name|udid] Set status bar overrides
          statusbar-clear [name|udid] Clear status bar overrides
          permission <action> <service> [bundle] [name|udid] Set privacy permission
          biometric-enroll <on|off> [name|udid] Set biometric enrollment
          biometric-match [match|nomatch] [name|udid] Trigger biometric result
          CONTENT AND INPUT
          open <url> [name|udid]      Open a deep link
          push [bundle]                 Send a push notification payload
          addmedia <path> [path ...]    Add media to the photo library
          pasteboard [--set <text>]     Read or set the device pasteboard
          LOCATION
          location <lat> <lon> [dev]  Set the simulator's GPS position
          scenarios [name|udid]         List built-in location scenarios
          route <scenario> [name|udid]  Run a location scenario
          location-clear [name|udid]    Clear a location scenario
          INSPECTION
          defaults <bundle>              Read app UserDefaults
          defaults-write <bundle> <key> <value> Write an app UserDefaults value
          defaults-delete <bundle> <key> Delete an app UserDefaults value
          logs [--last <duration>]       Read a bounded simulator log window
          keychain <path> [name|udid] Add-root-cert trusts a CA for HTTPS debugging
          keychain-reset [name|udid]  Reset the simulator keychain
          proxy-status                Read the system proxy inherited by simulators
          agent start|stop|status     Start, stop, or inspect the UI driver
          agent stream [options]      Stream simulator to browser for feedback
          feedback next|list|ack|clear|prompt Read and manage human stream comments
          ui tree|tap|press|swipe     Inspect and drive the app UI
          ui type|button|alert        Type text or press UI/hardware controls
          ui wait|do                  Wait for elements or run action sequences
          ui screenshot|find          Capture or search the UI
          doctor                      Check local simulator and driver setup
          mcp                         Run as an MCP server over stdio (for AI agents)
          help                        Show this message

        OPTIONS
          --output <path>             Where to write a capture (default: ./)
          --json                      Emit machine-readable JSON on stdout
          --duration <seconds>        Recording duration (for record)
          --payload <json>            Push payload (takes precedence over file/stdin)
          --payload-file <path>       Read a push payload from a file
          --type <type>               Defaults type: string, bool, int, float, array, dict
          --last <duration>           Log window: 30s, 5m, or 1h (default: 1m)
          --predicate <text>          Predicate for logs
          --bundle <bundle-id>        Logs convenience subsystem predicate
          --set <text>                Set pasteboard contents
          statusbar flags             time, dataNetwork, wifiMode, wifiBars,
                                      cellularMode, cellularBars, operatorName,
                                      batteryState, batteryLevel
          Push input precedence: --payload, then --payload-file, then stdin.

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

    public static func perform(command: String, args: [String], output: String? = nil, duration: Double? = nil) throws -> CommandOutcome {
        try performInternal(command: command, args: args, output: output, duration: duration)
    }

    private static func performInternal(command: String, args: [String], output: String?, duration: Double?) throws -> CommandOutcome {
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

        case "apps":
            let device = try resolveDevice(args.first)
            let apps = try parseInstalledApps(runSimctl(["listapps", device.udid]))
            let human = apps.map { "\($0.bundleID)  \($0.name)  \($0.path)" }.joined(separator: "\n")
            return CommandOutcome(human: human, json: AppsPayload(udid: device.udid, name: device.name, apps: apps))

        case "install":
            guard let path = args.first, !path.isEmpty else {
                throw CLIError(commandError: CommandError(code: .usage, message: "usage: cosmokit install <path> [name|udid] (missing path)"))
            }
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            try runSimctl(["install", device.udid, path])
            return CommandOutcome(human: "Installed \(path) on \(device.name)", json: InstallPayload(udid: device.udid, name: device.name, path: path))

        case "uninstall":
            let bundleID = try requiredBundle(args, command: "uninstall")
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            try runSimctl(["uninstall", device.udid, bundleID])
            return CommandOutcome(human: "Uninstalled \(bundleID) from \(device.name)", json: UninstallPayload(udid: device.udid, name: device.name, bundleID: bundleID))

        case "launch":
            let bundleID = try requiredBundle(args, command: "launch")
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            let simctlOutput = try runSimctl(["launch", device.udid, bundleID])
            let pid = simctlOutput.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }.first
            try Driver.ensureTargetApp(bundleID, device: device.udid)
            return CommandOutcome(human: simctlOutput.trimmingCharacters(in: .whitespacesAndNewlines), json: LaunchPayload(udid: device.udid, name: device.name, bundleID: bundleID, pid: pid))

        case "terminate":
            let bundleID = try requiredBundle(args, command: "terminate")
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            try runSimctl(["terminate", device.udid, bundleID])
            return CommandOutcome(human: "Terminated \(bundleID) on \(device.name)", json: TerminatePayload(udid: device.udid, name: device.name, bundleID: bundleID))

        case "container":
            let bundleID = try requiredBundle(args, command: "container")
            let kind: String
            if args.count < 2 {
                kind = "app"
            } else if ["app", "data", "groups"].contains(args[1]) {
                kind = args[1]
            } else {
                throw CLIError(commandError: CommandError(code: .usage, message: "usage: cosmokit container <bundle> [app|data|groups] [name|udid]"))
            }
            let device = try resolveDevice(args.count > 2 ? args[2] : nil)
            let simctlArgs = kind == "app" ? ["get_app_container", device.udid, bundleID] : ["get_app_container", device.udid, bundleID, kind]
            let path = try runSimctl(simctlArgs).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandOutcome(human: path, json: ContainerPayload(udid: device.udid, name: device.name, bundleID: bundleID, kind: kind, path: path))

        case "appearance":
            let value = args.first.flatMap { ["light", "dark"].contains($0) ? $0 : nil }
            if args.first != nil && value == nil {
                throw CLIError(commandError: CommandError(code: .usage, message: "appearance must be one of: light, dark"))
            }
            let device = try resolveDevice(value == nil ? args.first : (args.count > 1 ? args[1] : nil))
            let simctlArgs = value.map { ["ui", device.udid, "appearance", $0] } ?? ["ui", device.udid, "appearance"]
            let appearance = try runSimctl(simctlArgs).trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandOutcome(human: appearance, json: AppearancePayload(udid: device.udid, name: device.name, appearance: appearance))

        case "statusbar":
            let parsed = try parseStatusBar(args)
            let device = try resolveDevice(parsed.device)
            guard !parsed.overrides.isEmpty else {
                throw CLIError(commandError: CommandError(code: .usage, message: "statusbar requires at least one override"))
            }
            var simctlArgs = ["status_bar", device.udid, "override"]
            for (flag, value) in parsed.overrides { simctlArgs += ["--\(flag)", value] }
            try runSimctl(simctlArgs)
            return CommandOutcome(human: "Overrode status bar on \(device.name)", json: StatusBarPayload(udid: device.udid, name: device.name, overrides: parsed.overrides))

        case "statusbar-clear":
            let device = try resolveDevice(args.first)
            try runSimctl(["status_bar", device.udid, "clear"])
            return CommandOutcome(human: "Cleared status bar on \(device.name)", json: StatusBarClearPayload(udid: device.udid, name: device.name))

        case "permission":
            let permission = try parsePermission(args)
            let device = try resolveDevice(permission.device)
            var simctlArgs = ["privacy", device.udid, permission.action, permission.service]
            if let bundleID = permission.bundleID { simctlArgs.append(bundleID) }
            try runSimctl(simctlArgs)
            return CommandOutcome(human: "Set \(permission.action) \(permission.service) on \(device.name)", json: PermissionPayload(udid: device.udid, name: device.name, action: permission.action, service: permission.service, bundleID: permission.bundleID))

        case "biometric-enroll":
            guard let raw = args.first, ["on", "off"].contains(raw) else {
                throw CLIError(commandError: CommandError(code: .usage, message: "biometric-enroll requires on or off"))
            }
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            let value = raw == "on" ? "1" : "0"
            try runSimctl(["spawn", device.udid, "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", value])
            try runSimctl(["spawn", device.udid, "notifyutil", "-p", "com.apple.BiometricKit.enrollmentChanged"])
            return CommandOutcome(human: "Biometric enrollment \(raw) on \(device.name)", json: BiometricEnrollPayload(udid: device.udid, name: device.name, enrolled: raw == "on"))

        case "biometric-match":
            let result = args.first.flatMap { ["match", "nomatch"].contains($0) ? $0 : nil } ?? "match"
            if args.first != nil && !["match", "nomatch"].contains(args.first!) {
                throw CLIError(commandError: CommandError(code: .usage, message: "biometric-match result must be match or nomatch"))
            }
            let device = try resolveDevice(result == args.first ? (args.count > 1 ? args[1] : nil) : args.first)
            let notification = result == "match" ? "com.apple.BiometricKit_Sim.fingerTouch.match" : "com.apple.BiometricKit_Sim.fingerTouch.nomatch"
            try runSimctl(["spawn", device.udid, "notifyutil", "-p", notification])
            return CommandOutcome(human: "Biometric \(result) on \(device.name)", json: BiometricMatchPayload(udid: device.udid, name: device.name, result: result))

        case "push":
            let parsed = try parsePush(args)
            let device = try resolveDevice(parsed.device)
            let bundle = parsed.bundleID ?? parsed.targetBundle
            _ = try runSimctlInput(["push", device.udid, bundle, "-"], input: parsed.data)
            return CommandOutcome(human: "Sent push to \(device.name)", json: PushPayload(udid: device.udid, name: device.name, bundleID: parsed.bundleID ?? parsed.targetBundle, payloadBytes: parsed.data.count))

        case "scenarios":
            let device = try resolveDevice(args.first)
            let scenarios = parseScenarios(try runSimctl(["location", device.udid, "list"])).sorted()
            return CommandOutcome(human: scenarios.joined(separator: "\n"), json: ScenariosPayload(udid: device.udid, name: device.name, scenarios: scenarios))

        case "route":
            guard let scenario = args.first, !scenario.isEmpty else { throw CLIError(commandError: CommandError(code: .usage, message: "route requires a scenario")) }
            let device = try resolveDevice(args.count > 1 ? args[1] : nil)
            try runSimctl(["location", device.udid, "run", scenario])
            return CommandOutcome(human: "Running route \(scenario) on \(device.name)", json: RoutePayload(udid: device.udid, name: device.name, scenario: scenario))

        case "location-clear":
            let device = try resolveDevice(args.first)
            try runSimctl(["location", device.udid, "clear"])
            return CommandOutcome(human: "Cleared location on \(device.name)", json: LocationClearPayload(udid: device.udid, name: device.name))

        case "addmedia":
            let (paths, deviceQuery) = try parseMediaArgs(args)
            let device = try resolveDevice(deviceQuery)
            for path in paths where !FileManager.default.fileExists(atPath: path) { throw CLIError(commandError: CommandError(code: .usage, message: "media path does not exist: \(path)")) }
            try runSimctl(["addmedia", device.udid] + paths)
            return CommandOutcome(human: "Added \(paths.count) media file(s) to \(device.name)", json: AddMediaPayload(udid: device.udid, name: device.name, paths: paths, count: paths.count))

        case "pasteboard":
            let (text, deviceQuery, readsStdin) = parsePasteboardArgs(args)
            let device = try resolveDevice(deviceQuery)
            if readsStdin {
                let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
                _ = try runSimctlInput(["pbcopy", device.udid], input: Data(text.utf8))
                return CommandOutcome(human: "Set pasteboard on \(device.name)", json: PasteboardPayload(udid: device.udid, name: device.name, contents: text, didSet: true))
            } else if let text {
                _ = try runSimctlInput(["pbcopy", device.udid], input: Data(text.utf8))
                return CommandOutcome(human: "Set pasteboard on \(device.name)", json: PasteboardPayload(udid: device.udid, name: device.name, contents: text, didSet: true))
            }
            let contents = try runSimctl(["pbpaste", device.udid])
            return CommandOutcome(human: contents, json: PasteboardPayload(udid: device.udid, name: device.name, contents: contents, didSet: false))

        case "defaults":
            let parsed = try parseDefaultsReadArgs(args)
            let device = try resolveDevice(parsed.device)
            let (entries, note) = try readDefaults(device: device, bundleID: parsed.bundleID)
            let human = entries.map { "\($0.key) = \($0.value) (\($0.type))" }.joined(separator: "\n")
            return CommandOutcome(human: human.isEmpty ? (note ?? "") : human, json: DefaultsPayload(udid: device.udid, name: device.name, bundleID: parsed.bundleID, entries: entries, note: note))

        case "defaults-write":
            let parsed = try parseDefaultsWriteArgs(args)
            let device = try resolveDevice(parsed.device)
            let path = try defaultsPath(device: device, bundleID: parsed.bundleID)
            try runSimctl(["spawn", device.udid, "defaults", "write", path, parsed.key, parsed.flag, parsed.value])
            return CommandOutcome(human: "Wrote default \(parsed.key) for \(parsed.bundleID) on \(device.name); restart the app for the change to take effect", json: DefaultsWritePayload(udid: device.udid, name: device.name, bundleID: parsed.bundleID, key: parsed.key, value: parsed.value, type: parsed.type))

        case "defaults-delete":
            let parsed = try parseDefaultsDeleteArgs(args)
            let device = try resolveDevice(parsed.device)
            let path = try defaultsPath(device: device, bundleID: parsed.bundleID)
            try runSimctl(["spawn", device.udid, "defaults", "delete", path, parsed.key])
            return CommandOutcome(human: "Deleted default \(parsed.key) for \(parsed.bundleID) on \(device.name); restart the app for the change to take effect", json: DefaultsDeletePayload(udid: device.udid, name: device.name, bundleID: parsed.bundleID, key: parsed.key))

        case "logs":
            let parsed = try parseLogsArgs(args)
            let device = try resolveDevice(parsed.device)
            var simctlArgs = ["spawn", device.udid, "log", "show", "--last", parsed.window, "--style", "compact"]
            if let predicate = parsed.predicate { simctlArgs += ["--predicate", predicate] }
            let output = try runSimctl(simctlArgs)
            let parsedLines = parseLogLines(output)
            let lines = Array(parsedLines.suffix(500))
            let payload = LogsPayload(udid: device.udid, name: device.name, lines: lines, totalLines: parsedLines.count, truncated: parsedLines.count > 500, predicate: parsed.predicate, window: parsed.window)
            return CommandOutcome(human: lines.joined(separator: "\n"), json: payload)

        case "runtimes":
            let runtimes = try parseRuntimes(try runSimctl(["list", "runtimes", "--json"]))
            let deviceTypes = try parseDeviceTypes(try runSimctl(["list", "devicetypes", "--json"]))
            let payload = RuntimesPayload(runtimes: runtimes, deviceTypes: deviceTypes)
            return CommandOutcome(human: runtimes.map { "\($0.name)  \($0.identifier)" }.joined(separator: "\n"), json: payload)

        case "keychain":
            let parsed = try parseKeychainArgs(args)
            let device = try resolveDevice(parsed.device)
            let source = URL(fileURLWithPath: parsed.path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: source) else { throw usage("certificate path does not exist: \(source)") }
            let staged = try stageCertificate(source)
            let cleanupURL = staged.cleanupURL
            defer { if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) } }
            let action = parsed.untrusted ? "add-cert" : "add-root-cert"
            _ = try runSimctlTimed(["keychain", device.udid, action, staged.installPath], timeout: 180)
            return CommandOutcome(human: "\(action) installed on \(device.name): \(source)", json: KeychainPayload(udid: device.udid, name: device.name, action: action, path: source))

        case "keychain-reset":
            let device = try resolveDevice(args.first)
            _ = try runSimctlTimed(["keychain", device.udid, "reset"], timeout: 180)
            return CommandOutcome(human: "Reset keychain on \(device.name)", json: KeychainPayload(udid: device.udid, name: device.name, action: "reset", path: nil))

        case "proxy-status":
            let payload = parseProxyStatus(proxySourceForTesting())
            return CommandOutcome(human: proxyHumanText(payload), json: payload)

        case "throttle":
            return try performThrottle(args)

        case "offline":
            return try performOffline(args)

        case "agent":
            guard let action = args.first else { throw usage("usage: cosmokit agent start|stop|status|stream [name|udid] [--port N]") }
            if action == "stream" {
                return try performAgentStream(Array(args.dropFirst()))
            }
            guard ["start", "stop", "status"].contains(action) else { throw usage("usage: cosmokit agent start|stop|status|stream [name|udid] [--port N]") }
            let device = args.dropFirst().first(where: { !$0.hasPrefix("--") })
            if action == "status" { return CommandOutcome(human: Driver.status(device: device).running ? "Driver running" : "Driver stopped", json: Driver.status(device: device)) }
            if action == "stop" { let result = try Driver.stop(device: device); return CommandOutcome(human: result.message, json: result) }
            var port = 8877; if let index = args.firstIndex(of: "--port"), index + 1 < args.count, let value = Int(args[index + 1]) { port = value }
            let result = try Driver.start(device: device, port: port); return CommandOutcome(human: "Driver running on port \(result.port ?? port)", json: result)

        case "feedback":
            return try performFeedback(args)

        case "ui":
            return try performUI(args)

        case "doctor":
            let result = Doctor.run(); return CommandOutcome(human: result.lines.joined(separator: "\n"), json: result)

        default:
            throw CLIError(commandError: CommandError(code: .unknownCommand, message: "Unknown command: \(command)"))
        }
    }

    private static func performUI(_ args: [String]) throws -> CommandOutcome {
        guard let action = args.first else { throw usage("usage: cosmokit ui tree|tap|press|swipe|type|button|alert|screenshot|find|wait|do") }
        switch action {
        case "tree":
            var mode = UITreeMode.act; var depth: String?; var max = 80; var app: String?; var index = 1
            while index < args.count { switch args[index] { case "--mode": guard index + 1 < args.count, let value = UITreeMode(rawValue: args[index + 1]) else { throw usage("mode must be nav, act, or debug") }; mode = value; index += 2; case "--depth": guard index + 1 < args.count else { throw usage("--depth requires a value") }; depth = args[index + 1]; index += 2; case "--max": guard index + 1 < args.count, let value = Int(args[index + 1]), value > 0 else { throw usage("--max requires a positive integer") }; max = value; index += 2; case "--app": guard index + 1 < args.count else { throw usage("--app requires a bundle id") }; app = args[index + 1]; index += 2; default: index += 1 } }
            if let app { try Driver.ensureTargetApp(app) }
            var query: [String: Any] = [:]; if let depth { query["depth"] = Int(depth) ?? depth }; if let app { query["app"] = app }
            let data = try Driver.call("/tree", method: "GET", json: query.isEmpty ? nil : query)
            var snapshot = try UITree.parse(data)
            let hash = UITree.screenHash(snapshot)
            snapshot.screen = hash
            return CommandOutcome(human: UITree.compact(snapshot, mode: mode, maxLines: max), json: snapshot)
        case "find":
            var searchApp: String?
            var findArgs: [String] = []
            var fi = 1
            while fi < args.count {
                if args[fi] == "--app" && fi + 1 < args.count {
                    searchApp = args[fi + 1]
                    fi += 2
                } else {
                    findArgs.append(args[fi])
                    fi += 1
                }
            }
            guard !findArgs.isEmpty else { throw usage("ui find requires text") }
            if let searchApp { try Driver.ensureTargetApp(searchApp) }
            var findQuery: [String: Any] = [:]
            if let searchApp { findQuery["app"] = searchApp }
            let snapshot = try UITree.parse(Driver.call("/tree", method: "GET", json: findQuery.isEmpty ? nil : findQuery))
            let matches = UITree.find(snapshot, text: findArgs.joined(separator: " "))
            return CommandOutcome(human: matches.map { "[\($0.ref)] \($0.type) \($0.label ?? $0.value ?? "")" }.joined(separator: "\n"), json: matches)
        case "tap":
            guard args.count > 1 else { throw usage("ui tap requires a ref or x,y") }; return try uiAction("/tap", args: Array(args.dropFirst()))
        case "press":
            guard args.count > 1 else { throw usage("ui press requires a ref") }; return try uiAction("/press", args: Array(args.dropFirst()))
        case "swipe":
            guard args.count > 1 else { throw usage("ui swipe requires a direction or coordinates") }; return try uiAction("/swipe", args: Array(args.dropFirst()))
        case "type":
            guard args.count > 1 else { throw usage("ui type requires text") }; return try uiAction("/type", args: Array(args.dropFirst()))
        case "button", "alert":
            guard args.count > 1 else { throw usage("ui \(action) requires an action") }; return try uiAction("/\(action)", args: Array(args.dropFirst()))
        case "screenshot":
            let output = args.firstIndex(of: "--output").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? FileManager.default.currentDirectoryPath
            let directory = URL(fileURLWithPath: output, isDirectory: true); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let path = directory.appendingPathComponent("CosmoKit-UI-\(Int(Date().timeIntervalSince1970)).png").path; let data = try Driver.call("/screenshot"); try data.write(to: URL(fileURLWithPath: path)); return CommandOutcome(human: path, json: UIScreenshotPayload(path: path, width: 0, height: 0, bytes: data.count))
        case "wait":
            guard args.count > 1 else { throw usage("usage: cosmokit ui wait \"<text>\" [--timeout 10] [--gone] [--interval 0.3]") }
            var text = ""
            var timeout: Double = 10.0
            var gone = false
            var interval: Double = 0.3
            var waitApp: String?
            var index = 1
            while index < args.count {
                switch args[index] {
                case "--timeout" where index + 1 < args.count:
                    if let val = Double(args[index + 1]) { timeout = val }
                    index += 2
                case "--interval" where index + 1 < args.count:
                    if let val = Double(args[index + 1]) { interval = val }
                    index += 2
                case "--app" where index + 1 < args.count:
                    waitApp = args[index + 1]
                    index += 2
                case "--gone":
                    gone = true
                    index += 1
                default:
                    if !args[index].hasPrefix("--") && text.isEmpty {
                        text = args[index]
                    }
                    index += 1
                }
            }
            guard !text.isEmpty else { throw usage("ui wait requires search text") }
            if let waitApp { try Driver.ensureTargetApp(waitApp) }

            let start = Date()
            var waitQuery: [String: Any] = [:]
            if let waitApp { waitQuery["app"] = waitApp }
            while true {
                let data = try Driver.call("/tree", method: "GET", json: waitQuery.isEmpty ? nil : waitQuery)
                let snapshot = try UITree.parse(data)
                let matches = UITree.find(snapshot, text: text)
                if gone {
                    if matches.isEmpty {
                        let hash = UITree.screenHash(snapshot)
                        let human = "screen: \(hash)\ngone: \"\(text)\""
                        let payload = WaitPayload(screen: hash, ref: nil, element: nil, gone: true)
                        return CommandOutcome(human: human, json: payload)
                    }
                } else {
                    if let match = matches.first {
                        let hash = UITree.screenHash(snapshot)
                        let row = UITree.formatElement(match, mode: .act)
                        let human = "screen: \(hash)\n\(row)"
                        let elemPayload = FeedbackElementPayload(
                            ref: match.ref,
                            type: match.type,
                            label: match.label,
                            identifier: match.identifier,
                            frame: match.frame
                        )
                        let payload = WaitPayload(screen: hash, ref: match.ref, element: elemPayload, gone: false)
                        return CommandOutcome(human: human, json: payload)
                    }
                }
                if Date().timeIntervalSince(start) >= timeout {
                    throw CLIError(commandError: CommandError(
                        code: .timeout,
                        message: "Timed out waiting for \(gone ? "absence of " : "")\"\(text)\" after \(timeout)s"
                    ))
                }
                Thread.sleep(forTimeInterval: interval)
            }
        case "do":
            guard args.count > 1 else { throw usage("usage: cosmokit ui do [--screen <hash>] [--app <bundle>] <step> [<step>...]") }
            var screenHash: String? = nil
            var doApp: String? = nil
            var steps: [String] = []
            var index = 1
            while index < args.count {
                if args[index] == "--screen" && index + 1 < args.count {
                    screenHash = args[index + 1]
                    index += 2
                } else if args[index] == "--app" && index + 1 < args.count {
                    doApp = args[index + 1]
                    index += 2
                } else {
                    steps.append(args[index])
                    index += 1
                }
            }
            guard !steps.isEmpty else { throw usage("ui do requires at least one step") }
            if let doApp { try Driver.ensureTargetApp(doApp) }

            for (i, step) in steps.enumerated() {
                var stepArgs = splitArguments(step)
                if stepArgs.first == "ui" { stepArgs.removeFirst() }
                if i == 0, let screenHash, !stepArgs.contains("--screen") {
                    stepArgs += ["--screen", screenHash]
                }
                if let doApp, !stepArgs.contains("--app") {
                    stepArgs += ["--app", doApp]
                }
                do {
                    _ = try performUI(stepArgs)
                } catch let error as CLIError {
                    let stepNum = i + 1
                    let msg = "Step \(stepNum) of \(steps.count) failed ('\(step)'): \(error.commandError.message)"
                    let err = CommandError(
                        code: error.commandError.code,
                        message: msg,
                        expected: error.commandError.expected,
                        actual: error.commandError.actual
                    )
                    throw CLIError(commandError: err)
                } catch {
                    let stepNum = i + 1
                    let msg = "Step \(stepNum) of \(steps.count) failed ('\(step)'): \(error.localizedDescription)"
                    throw CLIError(commandError: CommandError(code: .usage, message: msg))
                }
            }

            var treeQuery: [String: Any] = [:]
            if let doApp { treeQuery["app"] = doApp }
            let data = try Driver.call("/tree", method: "GET", json: treeQuery.isEmpty ? nil : treeQuery)
            var snapshot = try UITree.parse(data)
            let hash = UITree.screenHash(snapshot)
            snapshot.screen = hash
            let human = UITree.compact(snapshot, mode: .act)
            let payload = DoPayload(screen: hash, stepsCompleted: steps.count, totalSteps: steps.count, app: snapshot.app)
            return CommandOutcome(human: human, json: payload)
        default: throw usage("unknown ui action \(action)")
        }
    }

    public static func splitArguments(_ string: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in string {
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch == " " && !inSingle && !inDouble {
                if !current.isEmpty { args.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    private static func uiAction(_ path: String, args: [String]) throws -> CommandOutcome {
        var cleanArgs = args
        var targetApp: String?
        if let appIdx = cleanArgs.firstIndex(of: "--app"), appIdx + 1 < cleanArgs.count {
            targetApp = cleanArgs[appIdx + 1]
            cleanArgs.removeSubrange(appIdx...appIdx + 1)
        }
        if let targetApp {
            try Driver.ensureTargetApp(targetApp)
        }
        if let screenIdx = cleanArgs.firstIndex(of: "--screen"), screenIdx + 1 < cleanArgs.count {
            let expectedHash = cleanArgs[screenIdx + 1]
            cleanArgs.removeSubrange(screenIdx...screenIdx + 1)
            var query: [String: Any] = [:]
            if let targetApp { query["app"] = targetApp }
            let data = try Driver.call("/tree", method: "GET", json: query.isEmpty ? nil : query)
            let snapshot = try UITree.parse(data)
            let actualHash = UITree.screenHash(snapshot)
            if actualHash != expectedHash {
                throw CLIError(commandError: CommandError(
                    code: .screenChanged,
                    message: "Screen changed (expected \(expectedHash), actual \(actualHash))",
                    expected: expectedHash,
                    actual: actualHash
                ))
            }
        }
        var body: [String: Any] = [:]
        if let targetApp { body["app"] = targetApp }
        if let first = cleanArgs.first {
            if let ref = Int(first) {
                body["ref"] = ref
            } else if first.contains(",") {
                let values = first.split(separator: ",").compactMap { Double($0) }
                if values.count == 2 {
                    body["x"] = values[0]
                    body["y"] = values[1]
                } else {
                    body["action"] = cleanArgs.joined(separator: " ")
                }
            } else {
                body["action"] = cleanArgs.joined(separator: " ")
            }
        }
        if path == "/type" {
            if let intoIdx = cleanArgs.firstIndex(of: "--into"), intoIdx + 1 < cleanArgs.count, let ref = Int(cleanArgs[intoIdx + 1]) {
                body["ref"] = ref
                let textParts = cleanArgs.prefix(intoIdx)
                body["text"] = textParts.joined(separator: " ")
            } else {
                body["text"] = cleanArgs.joined(separator: " ")
            }
        }
        _ = try Driver.call(path, method: "POST", json: body)
        return CommandOutcome(human: "OK", json: DriverActionPayload(message: "OK"))
    }

    public static var startStreamForTesting: ((Device, Int, Double, Double, String) throws -> StreamStatusPayload)? = nil

    private static func spawnDaemon(device: Device, args: [String]) throws -> CommandOutcome {
        let executablePath: String = {
            if let path = Bundle.main.executablePath, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            if let argv0 = CommandLine.arguments.first, FileManager.default.isExecutableFile(atPath: argv0) {
                return argv0
            }
            return "/usr/local/bin/cosmokit"
        }()

        let logDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cosmokit")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("stream-\(device.udid).log").path

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // fd 0 -> /dev/null
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        // fd 1 & 2 -> logPath
        posix_spawn_file_actions_addopen(&fileActions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, 2, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // setsid to detach from controlling terminal
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // Child command: cosmokit agent stream <args minus --daemon> --foreground
        let childArgs = ["cosmokit", "agent", "stream"] + args.filter { $0 != "--daemon" } + ["--foreground"]
        var cArgs = childArgs.map { strdup($0) }
        cArgs.append(nil)
        defer { for ptr in cArgs where ptr != nil { free(ptr) } }

        var pid: pid_t = 0
        let spawnErr = posix_spawn(&pid, executablePath, &fileActions, &attr, cArgs, environ)
        guard spawnErr == 0 else {
            throw CLIError(commandError: CommandError(code: .driverUnavailable, message: "Failed to spawn daemon process (posix_spawn returned \(spawnErr))"))
        }

        // Parent waits up to 5s for pid file to appear
        let deadline = Date().addingTimeInterval(5.0)
        var status = StreamServer.status(device: device.udid)
        while !status.running && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            status = StreamServer.status(device: device.udid)
        }

        guard status.running, let url = status.url else {
            throw CLIError(commandError: CommandError(code: .driverUnavailable, message: "Stream daemon spawned (pid \(pid)), but failed to start within 5s. Check log at: \(logPath)"))
        }

        return CommandOutcome(human: url, json: status)
    }

    private static func performAgentStream(_ args: [String]) throws -> CommandOutcome {
        if args.first == "stop" {
            let deviceQuery = args.dropFirst().first(where: { !$0.hasPrefix("--") })
            let result = try StreamServer.stop(device: deviceQuery)
            return CommandOutcome(human: result.message, json: result)
        }
        if args.first == "status" {
            let deviceQuery = args.dropFirst().first(where: { !$0.hasPrefix("--") })
            let status = StreamServer.status(device: deviceQuery)
            return CommandOutcome(human: status.running ? "Stream running: \(status.url ?? "")" : "Stream stopped", json: status)
        }

        var port = 8878
        var fps = 4.0
        var scale = 0.5
        var openBrowser = false
        var daemon = false
        var foreground = false
        var source = "simctl"
        var deviceQuery: String? = nil

        var index = 0
        while index < args.count {
            switch args[index] {
            case "--port" where index + 1 < args.count:
                if let val = Int(args[index + 1]) { port = val }
                index += 2
            case "--fps" where index + 1 < args.count:
                if let val = Double(args[index + 1]) { fps = val }
                index += 2
            case "--scale" where index + 1 < args.count:
                if let val = Double(args[index + 1]) { scale = val }
                index += 2
            case "--open":
                openBrowser = true
                index += 1
            case "--daemon":
                daemon = true
                index += 1
            case "--foreground":
                foreground = true
                index += 1
            case "--source" where index + 1 < args.count:
                source = args[index + 1]
                index += 2
            default:
                if !args[index].hasPrefix("--") && deviceQuery == nil {
                    deviceQuery = args[index]
                }
                index += 1
            }
        }

        let device = try resolveDevice(deviceQuery)

        if let override = startStreamForTesting {
            let status = try override(device, port, fps, scale, source)
            return CommandOutcome(human: status.url ?? "http://127.0.0.1:\(port)/", json: status)
        }

        // If daemon is requested and this is not already the re-spawned foreground child, spawn daemon
        if daemon && !foreground {
            return try spawnDaemon(device: device, args: args)
        }

        let server = StreamServer(port: port, device: device, fps: fps, scale: scale, source: source)
        try server.start(openBrowser: openBrowser)

        let status = StreamStatusPayload(running: true, port: port, pid: Int(ProcessInfo.processInfo.processIdentifier), url: server.url)

        if daemon {
            return CommandOutcome(human: server.url, json: status)
        }

        if !foreground {
            print(server.url)
            fflush(stdout)
        }

        let pidFile = StreamServer.pidFile(for: device.udid)
        let cleanup = {
            try? FileManager.default.removeItem(at: pidFile)
            exit(0)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler(handler: cleanup)
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler(handler: cleanup)
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)

        RunLoop.current.run()
        return CommandOutcome(human: server.url, json: status)
    }

    private static func performFeedback(_ args: [String]) throws -> CommandOutcome {
        guard let action = args.first else {
            throw usage("usage: cosmokit feedback next|list|ack|clear [name|udid] [options]")
        }

        switch action {
        case "next":
            var wait: Double = 0
            var deviceQuery: String? = nil
            var index = 1
            while index < args.count {
                if args[index] == "--wait" {
                    if index + 1 < args.count, let val = Double(args[index + 1]) {
                        wait = val
                        index += 2
                    } else {
                        wait = 300
                        index += 1
                    }
                } else if !args[index].hasPrefix("--") {
                    deviceQuery = args[index]
                    index += 1
                } else {
                    index += 1
                }
            }
            let device = try resolveDevice(deviceQuery)
            guard let record = FeedbackStore.nextUnread(udid: device.udid, wait: wait) else {
                throw CLIError(commandError: CommandError(code: .timeout, message: "timed out waiting for feedback"))
            }
            let human = FeedbackStore.formatCompact(record)
            return CommandOutcome(human: human, json: record)

        case "list":
            let deviceQuery = args.dropFirst().first(where: { !$0.hasPrefix("--") })
            let device = try resolveDevice(deviceQuery)
            let records = FeedbackStore.readAll(udid: device.udid)
            let human = records.isEmpty ? "No feedback recorded." : records.map(FeedbackStore.formatCompact).joined(separator: "\n")
            return CommandOutcome(human: human, json: FeedbackListPayload(records: records))

        case "ack":
            guard args.count > 1, let seq = Int(args[1]) else {
                throw usage("usage: cosmokit feedback ack <seq> [name|udid]")
            }
            let deviceQuery = args.dropFirst(2).first(where: { !$0.hasPrefix("--") })
            let device = try resolveDevice(deviceQuery)
            guard let record = try FeedbackStore.ack(udid: device.udid, seq: seq) else {
                throw CLIError(commandError: CommandError(code: .usage, message: "no feedback record with seq #\(seq)"))
            }
            let human = FeedbackStore.formatCompact(record)
            return CommandOutcome(human: human, json: record)

        case "clear":
            let deviceQuery = args.dropFirst().first(where: { !$0.hasPrefix("--") })
            let device = try resolveDevice(deviceQuery)
            let count = try FeedbackStore.clear(udid: device.udid)
            let human = "Cleared \(count) feedback record(s) on \(device.name)"
            return CommandOutcome(human: human, json: FeedbackClearPayload(cleared: true, count: count))

        case "prompt":
            var seq: Int? = nil
            var scope = "unacked"
            var deviceQuery: String? = nil
            var index = 1
            while index < args.count {
                switch args[index] {
                case "--seq":
                    guard index + 1 < args.count, let val = Int(args[index + 1]) else {
                        throw usage("usage: cosmokit feedback prompt [--seq N | --all | --unacked] [name|udid]")
                    }
                    seq = val
                    index += 2
                case "--all":
                    scope = "all"
                    index += 1
                case "--unacked":
                    scope = "unacked"
                    index += 1
                default:
                    if !args[index].hasPrefix("--") && deviceQuery == nil {
                        deviceQuery = args[index]
                    }
                    index += 1
                }
            }
            let device = try resolveDevice(deviceQuery)
            let records = FeedbackStore.readAll(udid: device.udid)
            let selectedRecords: [FeedbackRecordPayload]
            if let seq = seq {
                guard let target = records.first(where: { $0.seq == seq }) else {
                    throw CLIError(commandError: CommandError(code: .usage, message: "no feedback record with seq #\(seq)"))
                }
                selectedRecords = [target]
            } else if scope == "all" {
                selectedRecords = records
            } else {
                selectedRecords = records.filter { ($0.acked ?? false) == false }
            }
            let rendered = FeedbackPrompt.render(selectedRecords, app: nil)
            return CommandOutcome(human: rendered, json: FeedbackPromptPayload(text: rendered))

        default:
            throw usage("usage: cosmokit feedback next|list|ack|clear|prompt [name|udid] [options]")
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

    public static func parseInstalledApps(_ raw: String) throws -> [InstalledApp] {
        let object = try PropertyListSerialization.propertyList(from: Data(raw.utf8), format: nil)
        guard let dictionary = object as? [String: Any] else { return [] }
        return dictionary.values.compactMap { $0 as? [String: Any] }.compactMap { entry in
            let bundleID = (entry["CFBundleIdentifier"] as? String) ?? ""
            guard !bundleID.isEmpty else { return nil }
            let name = (entry["CFBundleDisplayName"] as? String) ?? (entry["CFBundleName"] as? String) ?? bundleID
            let path = (entry["Bundle"] as? String) ?? (entry["Path"] as? String) ?? ""
            let type = (entry["ApplicationType"] as? String) ?? ""
            return InstalledApp(bundleID: bundleID, name: name, path: path, type: type)
        }.sorted { $0.bundleID < $1.bundleID }
    }

    public static func parseScenarios(_ raw: String) -> [String] {
        let names = raw.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) == false else { return nil }
            let firstColumn = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
            if firstColumn == "Name" { return nil }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            var name = trimmed
            if let range = trimmed.range(of: " {2,}", options: .regularExpression) {
                name = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return name.isEmpty ? nil : (parts.isEmpty ? firstColumn : name)
        }
        return Array(Set(names)).sorted()
    }

    /// The push payload rules, in one place. Both surfaces call this so the
    /// message an agent sees and the message a terminal user sees stay identical.
    public static func validatePushPayload(_ data: Data, bundleID: String?) throws -> (bundle: String, byteCount: Int) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIError(commandError: CommandError(code: .usage, message: "payload is not valid JSON: \(error.localizedDescription)"))
        }
        guard let dictionary = object as? [String: Any] else {
            throw CLIError(commandError: CommandError(code: .usage, message: "payload must be a JSON object at the top level"))
        }
        guard dictionary["aps"] != nil else { throw CLIError(commandError: CommandError(code: .usage, message: "payload must contain aps")) }
        guard data.count <= 4096 else { throw CLIError(commandError: CommandError(code: .usage, message: "payload is \(data.count) bytes; maximum is 4096")) }
        // An explicit bundle argument states this invocation's intent and wins over reusable payload metadata.
        let targetBundle = dictionary["Simulator Target Bundle"] as? String ?? ""
        guard let bundle = bundleID ?? (targetBundle.isEmpty ? nil : targetBundle) else {
            throw CLIError(commandError: CommandError(code: .usage, message: "bundle id is required unless payload contains Simulator Target Bundle"))
        }
        return (bundle, data.count)
    }

    public static func parseDefaultsEntries(_ raw: String) throws -> [DefaultsEntry] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let object = try PropertyListSerialization.propertyList(from: Data(raw.utf8), format: nil)
        guard let dictionary = object as? [String: Any] else { return [] }
        return dictionary.keys.sorted().map { key in
            let value = dictionary[key]!
            return DefaultsEntry(key: key, value: String(describing: value), type: defaultsType(value))
        }
    }

    public static func parseLogLines(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    public static func validateLogWindow(_ raw: String) throws -> String {
        guard raw.range(of: "^[1-9][0-9]*[smh]$", options: .regularExpression) != nil else {
            throw CLIError(commandError: CommandError(code: .usage, message: "--last must be a duration such as 30s, 5m, or 1h"))
        }
        return raw
    }

    public static func parsePush(_ args: [String]) throws -> (data: Data, bundleID: String?, targetBundle: String, device: String?) {
        var bundleID: String?
        var payload: String?
        var payloadFile: String?
        var device: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--payload":
                guard index + 1 < args.count else { throw CLIError(commandError: CommandError(code: .usage, message: "--payload requires JSON")) }
                payload = args[index + 1]; index += 2
            case "--payload-file":
                guard index + 1 < args.count else { throw CLIError(commandError: CommandError(code: .usage, message: "--payload-file requires a path")) }
                payloadFile = args[index + 1]; index += 2
            case "--device":
                guard index + 1 < args.count else { throw CLIError(commandError: CommandError(code: .usage, message: "--device requires a value")) }
                device = args[index + 1]; index += 2
            default:
                if bundleID == nil { bundleID = args[index] } else if device == nil { device = args[index] }
                index += 1
            }
        }
        let data: Data
        if let payload { data = Data(payload.utf8) }
        else if let payloadFile { guard let fileData = FileManager.default.contents(atPath: payloadFile) else { throw CLIError(commandError: CommandError(code: .usage, message: "payload file does not exist: \(payloadFile)")) }; data = fileData }
        else { data = FileHandle.standardInput.readDataToEndOfFile() }
        let validation = try validatePushPayload(data, bundleID: bundleID)
        return (data, bundleID, validation.bundle, device)
    }

    private static func parseMediaArgs(_ args: [String]) throws -> ([String], String?) {
        var paths = args
        var device: String?
        if let index = paths.firstIndex(of: "--device") {
            guard index + 1 < paths.count else { throw CLIError(commandError: CommandError(code: .usage, message: "--device requires a value")) }
            device = paths[index + 1]
            paths.removeSubrange(index...index + 1)
        }
        guard !paths.isEmpty else { throw CLIError(commandError: CommandError(code: .usage, message: "addmedia requires at least one path")) }
        return (paths, device)
    }

    private static func parsePasteboardArgs(_ args: [String]) -> (String?, String?, Bool) {
        guard let index = args.firstIndex(of: "--set") else { return (nil, args.first, false) }
        let readsStdin = index + 1 >= args.count
        let text = readsStdin ? nil : args[index + 1]
        let device = index + 2 < args.count ? args[index + 2] : nil
        return (text, device, readsStdin)
    }

    private static func parseKeychainArgs(_ args: [String]) throws -> (path: String, device: String?, untrusted: Bool) {
        guard let path = args.first, !path.isEmpty else { throw usage("keychain requires a certificate path") }
        let untrusted = args.contains("--untrusted")
        let positional = args.filter { $0 != "--untrusted" }
        return (path, positional.count > 1 ? positional[1] : nil, untrusted)
    }

    // CoreSimulatorService cannot read another app's sandbox container, so stage
    // container certificates outside it before simctl opens the file.
    private static func stageCertificate(_ source: String) throws -> (installPath: String, cleanupURL: URL?) {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let containerPrefix = home + "/Library/Containers/"
        guard source.hasPrefix(containerPrefix) else {
            return (source, nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cosmokit-keychain-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent(URL(fileURLWithPath: source).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: source, toPath: destination.path)
            return (destination.path, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return (source, nil)
        }
    }

    private static func runSimctlTimed(_ arguments: [String], timeout: TimeInterval) throws -> String {
        do { return try runSimctlTimedForTesting(arguments, timeout) }
        catch { throw CLIError(commandError: CommandError(code: .simctlFailed, message: error.localizedDescription)) }
    }

    public static func parseProxyStatus(_ dictionary: [String: Any]?) -> ProxyStatusPayload {
        guard let dictionary else { return ProxyStatusPayload(httpEnabled: false, httpHost: nil, httpPort: nil, httpsEnabled: false, httpsHost: nil, httpsPort: nil, bypassList: []) }
        func bool(_ key: String) -> Bool { (dictionary[key] as? NSNumber)?.boolValue ?? false }
        func string(_ key: String) -> String? { dictionary[key] as? String }
        func integer(_ key: String) -> Int? { (dictionary[key] as? NSNumber)?.intValue }
        let bypass = (dictionary["ExceptionsList"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ProxyStatusPayload(httpEnabled: bool("HTTPEnable"), httpHost: string("HTTPProxy"), httpPort: integer("HTTPPort"), httpsEnabled: bool("HTTPSEnable"), httpsHost: string("HTTPSProxy"), httpsPort: integer("HTTPSPort"), bypassList: bypass)
    }

    public static func proxyHumanText(_ payload: ProxyStatusPayload) -> String {
        func line(_ label: String, enabled: Bool, host: String?, port: Int?) -> String {
            guard enabled else { return "\(label) off" }
            return "\(label) on at \(host ?? "unknown"):\(port.map(String.init) ?? "unknown")"
        }
        let bypass = payload.bypassList.isEmpty ? "" : " (\(payload.bypassList.count) bypass rules)"
        return "\(line("HTTP", enabled: payload.httpEnabled, host: payload.httpHost, port: payload.httpPort)), \(line("HTTPS", enabled: payload.httpsEnabled, host: payload.httpsHost, port: payload.httpsPort))\(bypass)"
    }

    private static func performThrottle(_ args: [String]) throws -> CommandOutcome {
        guard let first = args.first else {
            throw usage("usage: cosmokit throttle <edge|3g|lte|verybad|off|status|custom [options]>")
        }

        if first == "status" {
            let status = try AppControl.status()
            return CommandOutcome(human: AppControl.humanText(for: status), json: status)
        }

        if first == "custom" {
            var latencyMs: Int?
            var downKbps: Int?
            var upKbps: Int?
            var failurePct: Int?

            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--latency-ms":
                    guard index + 1 < args.count, let val = Int(args[index + 1]) else {
                        throw usage("--latency-ms requires an integer")
                    }
                    latencyMs = val
                    index += 2
                case "--down-kbps":
                    guard index + 1 < args.count, let val = Int(args[index + 1]) else {
                        throw usage("--down-kbps requires an integer")
                    }
                    downKbps = val
                    index += 2
                case "--up-kbps":
                    guard index + 1 < args.count, let val = Int(args[index + 1]) else {
                        throw usage("--up-kbps requires an integer")
                    }
                    upKbps = val
                    index += 2
                case "--failure-pct":
                    guard index + 1 < args.count, let val = Int(args[index + 1]) else {
                        throw usage("--failure-pct requires an integer")
                    }
                    failurePct = val
                    index += 2
                default:
                    throw usage("unknown option for throttle custom: \(arg)")
                }
            }

            var customDict: [String: Any] = [:]
            if let latencyMs { customDict["latencyMs"] = latencyMs }
            if let downKbps { customDict["downloadKbps"] = downKbps }
            if let upKbps { customDict["uploadKbps"] = upKbps }
            if let failurePct { customDict["failureRatePercent"] = failurePct }

            let status = try AppControl.throttle(preset: nil, custom: customDict)
            return CommandOutcome(human: AppControl.humanText(for: status), json: status)
        }

        let normalized: String
        switch first.lowercased() {
        case "edge":
            normalized = "edge"
        case "3g", "threeg":
            normalized = "threeG"
        case "lte":
            normalized = "lte"
        case "verybad":
            normalized = "veryBad"
        case "off":
            normalized = "off"
        case "offline":
            normalized = "offline"
        default:
            if ["edge", "threeG", "lte", "veryBad", "off", "offline"].contains(first) {
                normalized = first
            } else {
                throw usage("unknown preset '\(first)'; expected one of: edge, 3g, lte, verybad, off, custom, status")
            }
        }

        let status = try AppControl.throttle(preset: normalized, custom: nil)
        return CommandOutcome(human: AppControl.humanText(for: status), json: status)
    }

    private static func performOffline(_ args: [String]) throws -> CommandOutcome {
        guard let first = args.first else {
            throw usage("usage: cosmokit offline on|off")
        }
        let on: Bool
        switch first.lowercased() {
        case "on", "true", "1":
            on = true
        case "off", "false", "0":
            on = false
        default:
            throw usage("usage: cosmokit offline on|off")
        }

        let status = try AppControl.offline(on: on)
        return CommandOutcome(human: AppControl.humanText(for: status), json: status)
    }

    private static func parseDefaultsReadArgs(_ args: [String]) throws -> (bundleID: String, device: String?) {
        guard let bundleID = args.first, !bundleID.isEmpty else { throw usage("defaults requires a bundle id") }
        return (bundleID, args.count > 1 ? args[1] : nil)
    }

    private static func parseDefaultsWriteArgs(_ args: [String]) throws -> (bundleID: String, key: String, value: String, type: String, flag: String, device: String?) {
        var positional: [String] = []
        var type = "string"
        var device: String?
        var index = 0
        while index < args.count {
            if args[index] == "--type" {
                guard index + 1 < args.count else { throw usage("--type requires one of: string, bool, int, float, array, dict") }
                type = args[index + 1]; index += 2
            } else if args[index] == "--device" {
                guard index + 1 < args.count else { throw usage("--device requires a value") }
                device = args[index + 1]; index += 2
            } else {
                positional.append(args[index]); index += 1
            }
        }
        guard positional.count >= 3 else { throw usage("defaults-write requires <bundle> <key> <value>") }
        if device == nil, positional.count > 3 { device = positional[3] }
        let flags = ["string": "-string", "bool": "-bool", "int": "-int", "float": "-float", "array": "-array", "dict": "-dict"]
        guard let flag = flags[type] else { throw usage("type must be one of: \(flags.keys.sorted().joined(separator: ", "))") }
        var value = positional[2]
        switch type {
        case "bool":
            guard let normalized = normalizeBool(value) else { throw usage("bool value must be true, false, YES, NO, 1, or 0") }
            value = normalized
        case "int":
            guard let integer = Int(value) else { throw usage("int value must be an integer") }
            value = String(integer)
        case "float":
            guard let number = Double(value) else { throw usage("float value must be a number") }
            value = String(describing: number)
        default: break
        }
        return (positional[0], positional[1], value, type, flag, device)
    }

    private static func parseDefaultsDeleteArgs(_ args: [String]) throws -> (bundleID: String, key: String, device: String?) {
        guard args.count >= 2, !args[0].isEmpty, !args[1].isEmpty else { throw usage("defaults-delete requires <bundle> <key>") }
        return (args[0], args[1], args.count > 2 ? args[2] : nil)
    }

    private static func parseLogsArgs(_ args: [String]) throws -> (window: String, predicate: String?, device: String?) {
        var window = "1m"
        var predicate: String?
        var bundle: String?
        var device: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--last", "--predicate", "--bundle", "--device":
                guard index + 1 < args.count else { throw usage("(args[index]) requires a value") }
                let value = args[index + 1]
                switch args[index] {
                case "--last": window = try validateLogWindow(value)
                case "--predicate": predicate = value
                case "--bundle": bundle = value
                default: device = value
                }
                index += 2
            default:
                guard device == nil else { throw usage("logs accepts only one device") }
                device = args[index]; index += 1
            }
        }
        if predicate == nil, let bundle { predicate = "subsystem == \"\(bundle)\"" }
        return (window, predicate, device)
    }

    private static func usage(_ message: String) -> CLIError {
        CLIError(commandError: CommandError(code: .usage, message: message))
    }

    private static func normalizeBool(_ value: String) -> String? {
        switch value.lowercased() {
        case "true", "yes", "1": return "true"
        case "false", "no", "0": return "false"
        default: return nil
        }
    }

    private static func defaultsPath(device: Device, bundleID: String) throws -> String {
        let container = try runSimctl(["get_app_container", device.udid, bundleID, "data"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !container.isEmpty else { throw usage("simulator returned an empty data container path") }
        return "\(container)/Library/Preferences/\(bundleID)"
    }

    private static func readDefaults(device: Device, bundleID: String) throws -> ([DefaultsEntry], String?) {
        let path = try defaultsPath(device: device, bundleID: bundleID)
        do {
            let raw = try runSimctl(["spawn", device.udid, "defaults", "export", path, "-"])
            let entries = try parseDefaultsEntries(raw)
            if entries.isEmpty { return ([], "The app has written no defaults yet") }
            return (entries, nil)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("no such file") || message.contains("not exist") || message.contains("could not be opened") || message.contains("empty") {
                return ([], "The app has written no defaults yet")
            }
            throw error
        }
    }

    private static func defaultsType(_ value: Any) -> String {
        if value is String { return "string" }
        if value is Bool { return "bool" }
        if let number = value as? NSNumber {
            return String(cString: number.objCType) == "d" || String(cString: number.objCType) == "f" ? "float" : "integer"
        }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "dictionary" }
        if value is Data { return "data" }
        if value is Date { return "date" }
        return "string"
    }

    private static func parseRuntimes(_ raw: String) throws -> [Runtime] {
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let items = object?["runtimes"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let identifier = item["identifier"] as? String, let name = item["name"] as? String else { return nil }
            let version = item["version"] as? String ?? ""
            let availability = item["isAvailable"] as? Bool ?? ((item["availability"] as? String) == "(available)")
            return Runtime(identifier: identifier, name: name, version: version, isAvailable: availability)
        }
    }

    private static func parseDeviceTypes(_ raw: String) throws -> [DeviceType] {
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        let items = object?["devicetypes"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let identifier = item["identifier"] as? String, let name = item["name"] as? String else { return nil }
            return DeviceType(identifier: identifier, name: name)
        }
    }

    private static func parseStatusBar(_ args: [String]) throws -> (overrides: [String: String], device: String?) {
        let supported = Set(["time", "dataNetwork", "wifiMode", "wifiBars", "cellularMode", "cellularBars", "operatorName", "batteryState", "batteryLevel"])
        var overrides: [String: String] = [:]
        var device: String?
        var index = 0
        while index < args.count {
            guard args[index].hasPrefix("--") else { device = args[index]; index += 1; continue }
            let flag = String(args[index].dropFirst(2))
            guard supported.contains(flag), index + 1 < args.count else { throw CLIError(commandError: CommandError(code: .usage, message: "invalid statusbar flag or missing value: \(args[index])")) }
            let value = args[index + 1]
            if ["wifiBars", "cellularBars", "batteryLevel"].contains(flag) {
                guard Int(value) != nil else { throw CLIError(commandError: CommandError(code: .usage, message: "\(flag) must be an integer")) }
                if flag == "batteryLevel", let level = Int(value), !(0...100).contains(level) { throw CLIError(commandError: CommandError(code: .usage, message: "batteryLevel must be between 0 and 100")) }
            }
            overrides[flag] = value
            index += 2
        }
        return (overrides, device)
    }

    private static func parsePermission(_ args: [String]) throws -> (action: String, service: String, bundleID: String?, device: String?) {
        let actions = ["grant", "revoke", "reset"]
        let services = ["all", "calendar", "contacts-limited", "contacts", "location", "location-always", "photos-add", "photos", "media-library", "microphone", "motion", "reminders", "siri"]
        guard args.count >= 2, actions.contains(args[0]) else { throw CLIError(commandError: CommandError(code: .usage, message: "action must be one of: grant, revoke, reset")) }
        guard services.contains(args[1]) else { throw CLIError(commandError: CommandError(code: .usage, message: "service must be one of: \(services.joined(separator: ", "))")) }
        guard args[0] == "reset" || args.count >= 3 else { throw CLIError(commandError: CommandError(code: .usage, message: "grant and revoke require a bundle id")) }
        let bundleID = args.count > 2 ? args[2] : nil
        let device = args.count > 3 ? args[3] : nil
        return (args[0], args[1], bundleID, device)
    }

    private static func requiredBundle(_ args: [String], command: String) throws -> String {
        guard let bundle = args.first, !bundle.isEmpty else {
            throw CLIError(commandError: CommandError(code: .usage, message: "usage: cosmokit \(command) <bundle_id> [name|udid] (missing bundle_id)"))
        }
        return bundle
    }

    private static func resolveDevice(_ query: String?) throws -> Device {
        do {
            return try resolveDeviceForTesting(query)
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
            return try runSimctlForTesting(arguments)
        } catch {
            throw CLIError(commandError: CommandError(code: .simctlFailed, message: error.localizedDescription))
        }
    }

    private static func runSimctlInput(_ arguments: [String], input: Data) throws -> String {
        do { return try Simctl.run(arguments, input: input) }
        catch { throw CLIError(commandError: CommandError(code: .simctlFailed, message: error.localizedDescription)) }
    }

    private static func usageText() -> String {
        """
        cosmokit \(CLI.version) — drive the iOS Simulator from the command line

        USAGE
          cosmokit <command> [options]

        COMMANDS
          DISCOVERY
          list                        List available simulators
          runtimes                    List runtimes and device types
          LIFECYCLE
          boot [name|udid]            Boot a simulator (default: first available)
          shutdown [name|udid]        Shut a simulator down (default: booted)
          erase [name|udid]           Erase a simulator back to a fresh install
          APPS
          apps [name|udid]            List installed apps
          install <path> [name|udid]  Install an app bundle
          uninstall <bundle> [name|udid] Uninstall an app
          launch <bundle> [name|udid] Launch an app
          terminate <bundle> [name|udid] Terminate an app
          container <bundle> [kind] [name|udid] Get an app container path
          CAPTURE
          capture [name|udid]         Screenshot to a file
          record [name|udid]          Record video until you press Ctrl-C
          STATE
          appearance [light|dark] [name|udid] Set or read appearance
          statusbar [flags] [name|udid] Set status bar overrides
          statusbar-clear [name|udid] Clear status bar overrides
          permission <action> <service> [bundle] [name|udid] Set privacy permission
          biometric-enroll <on|off> [name|udid] Set biometric enrollment
          biometric-match [match|nomatch] [name|udid] Trigger biometric result
          CONTENT AND INPUT
          open <url> [name|udid]      Open a deep link
          push [bundle]               Send a push notification payload
          addmedia <path> [path ...]  Add media to the photo library
          pasteboard [--set <text>]   Read or set the device pasteboard
          LOCATION
          location <lat> <lon> [dev]  Set the simulator's GPS position
          scenarios [name|udid]       List built-in location scenarios
          route <scenario> [name|udid] Run a location scenario
          location-clear [name|udid] Clear a location scenario
          INSPECTION
          defaults <bundle>           Read app UserDefaults
          defaults-write <bundle> <key> <value> Write an app UserDefaults value
          defaults-delete <bundle> <key> Delete an app UserDefaults value
          logs [--last <duration>]    Read a bounded simulator log window
          keychain <path> [name|udid] Add-root-cert trusts a CA for HTTPS debugging
          keychain-reset [name|udid]  Reset the simulator keychain
          proxy-status                Read the system proxy inherited by simulators
          mcp                         Run as an MCP server over stdio (for AI agents)
          help                        Show this message

        OPTIONS
          --output <path>             Where to write a capture (default: ./)
          --json                      Emit machine-readable JSON on stdout
          --duration <seconds>        Recording duration (for record)
          --payload <json>            Push payload (takes precedence over file/stdin)
          --payload-file <path>       Read a push payload from a file
          --type <type>               Defaults type: string, bool, int, float, array, dict
          --last <duration>           Log window: 30s, 5m, or 1h (default: 1m)
          --predicate <text>          Predicate for logs
          --bundle <bundle-id>        Logs convenience subsystem predicate
          --set <text>                Set pasteboard contents
          statusbar flags             time, dataNetwork, wifiMode, wifiBars,
                                      cellularMode, cellularBars, operatorName,
                                      batteryState, batteryLevel
          Push input precedence: --payload, then --payload-file, then stdin.

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

public struct InstalledApp: Codable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let type: String

    public init(bundleID: String, name: String, path: String, type: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.type = type
    }
}

public struct AppsPayload: Codable {
    public let udid: String
    public let name: String
    public let apps: [InstalledApp]
    public init(udid: String, name: String, apps: [InstalledApp]) { self.udid = udid; self.name = name; self.apps = apps }
}

public struct InstallPayload: Codable {
    public let udid: String; public let name: String; public let path: String
    public init(udid: String, name: String, path: String) { self.udid = udid; self.name = name; self.path = path }
}

public struct UninstallPayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String
    public init(udid: String, name: String, bundleID: String) { self.udid = udid; self.name = name; self.bundleID = bundleID }
}

public struct LaunchPayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String; public let pid: Int?
    public init(udid: String, name: String, bundleID: String, pid: Int?) { self.udid = udid; self.name = name; self.bundleID = bundleID; self.pid = pid }
}

public struct TerminatePayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String
    public init(udid: String, name: String, bundleID: String) { self.udid = udid; self.name = name; self.bundleID = bundleID }
}

public struct ContainerPayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String; public let kind: String; public let path: String
    public init(udid: String, name: String, bundleID: String, kind: String, path: String) { self.udid = udid; self.name = name; self.bundleID = bundleID; self.kind = kind; self.path = path }
}

public struct AppearancePayload: Codable {
    public let udid: String; public let name: String; public let appearance: String
    public init(udid: String, name: String, appearance: String) { self.udid = udid; self.name = name; self.appearance = appearance }
}

public struct StatusBarPayload: Codable {
    public let udid: String; public let name: String; public let overrides: [String: String]
    public init(udid: String, name: String, overrides: [String: String]) { self.udid = udid; self.name = name; self.overrides = overrides }
}

public struct StatusBarClearPayload: Codable {
    public let udid: String; public let name: String
    public init(udid: String, name: String) { self.udid = udid; self.name = name }
}

public struct PermissionPayload: Codable {
    public let udid: String; public let name: String; public let action: String; public let service: String; public let bundleID: String?
    public init(udid: String, name: String, action: String, service: String, bundleID: String?) { self.udid = udid; self.name = name; self.action = action; self.service = service; self.bundleID = bundleID }
}

public struct BiometricEnrollPayload: Codable {
    public let udid: String; public let name: String; public let enrolled: Bool
    public init(udid: String, name: String, enrolled: Bool) { self.udid = udid; self.name = name; self.enrolled = enrolled }
}

public struct BiometricMatchPayload: Codable {
    public let udid: String; public let name: String; public let result: String
    public init(udid: String, name: String, result: String) { self.udid = udid; self.name = name; self.result = result }
}

public struct PushPayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String; public let payloadBytes: Int
    public init(udid: String, name: String, bundleID: String, payloadBytes: Int) { self.udid = udid; self.name = name; self.bundleID = bundleID; self.payloadBytes = payloadBytes }
}

public struct ScenariosPayload: Codable {
    public let udid: String; public let name: String; public let scenarios: [String]
    public init(udid: String, name: String, scenarios: [String]) { self.udid = udid; self.name = name; self.scenarios = scenarios }
}

public struct RoutePayload: Codable {
    public let udid: String; public let name: String; public let scenario: String
    public init(udid: String, name: String, scenario: String) { self.udid = udid; self.name = name; self.scenario = scenario }
}

public struct LocationClearPayload: Codable {
    public let udid: String; public let name: String
    public init(udid: String, name: String) { self.udid = udid; self.name = name }
}

public struct AddMediaPayload: Codable {
    public let udid: String; public let name: String; public let paths: [String]; public let count: Int
    public init(udid: String, name: String, paths: [String], count: Int) { self.udid = udid; self.name = name; self.paths = paths; self.count = count }
}

public struct PasteboardPayload: Codable {
    public let udid: String; public let name: String; public let contents: String; public let didSet: Bool
    public init(udid: String, name: String, contents: String, didSet: Bool) { self.udid = udid; self.name = name; self.contents = contents; self.didSet = didSet }
}

public struct DefaultsEntry: Codable {
    public let key: String
    public let value: String
    public let type: String
    public init(key: String, value: String, type: String) { self.key = key; self.value = value; self.type = type }
}

public struct DefaultsPayload: Codable {
    public let udid: String
    public let name: String
    public let bundleID: String
    public let entries: [DefaultsEntry]
    public let note: String?
    public init(udid: String, name: String, bundleID: String, entries: [DefaultsEntry], note: String?) {
        self.udid = udid; self.name = name; self.bundleID = bundleID; self.entries = entries; self.note = note
    }
}

public struct DefaultsWritePayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String; public let key: String; public let value: String; public let type: String
    public init(udid: String, name: String, bundleID: String, key: String, value: String, type: String) { self.udid = udid; self.name = name; self.bundleID = bundleID; self.key = key; self.value = value; self.type = type }
}

public struct DefaultsDeletePayload: Codable {
    public let udid: String; public let name: String; public let bundleID: String; public let key: String
    public init(udid: String, name: String, bundleID: String, key: String) { self.udid = udid; self.name = name; self.bundleID = bundleID; self.key = key }
}

public struct LogsPayload: Codable {
    public let udid: String; public let name: String; public let lines: [String]; public let totalLines: Int; public let truncated: Bool; public let predicate: String?; public let window: String
    public init(udid: String, name: String, lines: [String], totalLines: Int, truncated: Bool, predicate: String?, window: String) { self.udid = udid; self.name = name; self.lines = lines; self.totalLines = totalLines; self.truncated = truncated; self.predicate = predicate; self.window = window }
}

public struct Runtime: Codable {
    public let identifier: String; public let name: String; public let version: String; public let isAvailable: Bool
    public init(identifier: String, name: String, version: String, isAvailable: Bool) { self.identifier = identifier; self.name = name; self.version = version; self.isAvailable = isAvailable }
}

public struct DeviceType: Codable {
    public let identifier: String; public let name: String
    public init(identifier: String, name: String) { self.identifier = identifier; self.name = name }
}

public struct RuntimesPayload: Codable {
    public let runtimes: [Runtime]
    public let deviceTypes: [DeviceType]
    public init(runtimes: [Runtime], deviceTypes: [DeviceType]) { self.runtimes = runtimes; self.deviceTypes = deviceTypes }
}

public struct KeychainPayload: Codable {
    public let udid: String; public let name: String; public let action: String; public let path: String?
    public init(udid: String, name: String, action: String, path: String?) { self.udid = udid; self.name = name; self.action = action; self.path = path }
}

public struct ProxyStatusPayload: Codable {
    public let httpEnabled: Bool; public let httpHost: String?; public let httpPort: Int?
    public let httpsEnabled: Bool; public let httpsHost: String?; public let httpsPort: Int?; public let bypassList: [String]
    public init(httpEnabled: Bool, httpHost: String?, httpPort: Int?, httpsEnabled: Bool, httpsHost: String?, httpsPort: Int?, bypassList: [String]) {
        self.httpEnabled = httpEnabled; self.httpHost = httpHost; self.httpPort = httpPort; self.httpsEnabled = httpsEnabled; self.httpsHost = httpsHost; self.httpsPort = httpsPort; self.bypassList = bypassList
    }
}
