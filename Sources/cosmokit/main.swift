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

let version = "0.1.0"

func printUsage() {
    print("""
    cosmokit \(version) — drive the iOS Simulator from the command line

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
      help                        Show this message

    OPTIONS
      --output <path>             Where to write a capture (default: ./)

    EXAMPLES
      cosmokit capture --output ./screenshots
      cosmokit location -22.9068 -43.1729
      cosmokit open "myapp://item/42"
    """)
}

/// Pulls `--output <path>` out of the argument list, returning the rest.
func extractOutput(_ args: [String]) -> (output: String?, rest: [String]) {
    var output: String?
    var rest: [String] = []
    var index = 0
    while index < args.count {
        if args[index] == "--output", index + 1 < args.count {
            output = args[index + 1]
            index += 2
            continue
        }
        rest.append(args[index])
        index += 1
    }
    return (output, rest)
}

func timestampedPath(directory: String?, prefix: String, ext: String, deviceName: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let safeName = deviceName.replacingOccurrences(of: " ", with: "-")
    let filename = "\(prefix)-\(safeName)-\(formatter.string(from: Date())).\(ext)"
    let base = directory ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: base).appendingPathComponent(filename).path
}

func main() {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    guard let command = rawArgs.first else {
        printUsage()
        exit(0)
    }
    let (output, args) = extractOutput(Array(rawArgs.dropFirst()))

    do {
        switch command {
        case "help", "--help", "-h":
            printUsage()

        case "version", "--version":
            print(version)

        case "list":
            let devices = try Simctl.devices()
                .filter { $0.isAvailable }
                .sorted { $0.name < $1.name }
            guard !devices.isEmpty else {
                print("No available simulators.")
                return
            }
            for device in devices {
                let marker = device.isBooted ? "●" : "○"
                print("\(marker) \(device.name)  \(device.udid)  \(device.state)")
            }

        case "boot":
            let device: Device
            if let query = args.first {
                device = try Simctl.resolveDevice(query)
            } else if let firstShutdown = try Simctl.devices().first(where: { $0.isAvailable && !$0.isBooted }) {
                device = firstShutdown
            } else {
                throw SimctlError(message: "no available simulator to boot")
            }
            if device.isBooted {
                print("Already booted: \(device.name)")
            } else {
                try Simctl.run(["boot", device.udid])
                print("Booted \(device.name)")
            }

        case "shutdown":
            let device = try Simctl.resolveDevice(args.first)
            try Simctl.run(["shutdown", device.udid])
            print("Shut down \(device.name)")

        case "capture":
            let device = try Simctl.resolveDevice(args.first)
            let path = timestampedPath(
                directory: output, prefix: "CosmoKit-Screenshot", ext: "png", deviceName: device.name
            )
            try Simctl.run(["io", device.udid, "screenshot", path])
            print(path)

        case "record":
            let device = try Simctl.resolveDevice(args.first)
            let path = timestampedPath(
                directory: output, prefix: "CosmoKit-Recording", ext: "mp4", deviceName: device.name
            )
            print("Recording \(device.name). Press Ctrl-C to stop.")
            // simctl writes the file when it receives SIGINT, so hand the
            // terminal's Ctrl-C straight through to it.
            try Simctl.run(["io", device.udid, "recordVideo", path])
            print(path)

        case "location":
            guard args.count >= 2, let lat = Double(args[0]), let lon = Double(args[1]) else {
                throw SimctlError(message: "usage: cosmokit location <lat> <lon> [name|udid]")
            }
            let device = try Simctl.resolveDevice(args.count > 2 ? args[2] : nil)
            try Simctl.run(["location", device.udid, "set", "\(lat),\(lon)"])
            print("Set \(device.name) to \(lat), \(lon)")

        case "open":
            guard let url = args.first else {
                throw SimctlError(message: "usage: cosmokit open <url> [name|udid]")
            }
            let device = try Simctl.resolveDevice(args.count > 1 ? args[1] : nil)
            try Simctl.run(["openurl", device.udid, url])
            print("Opened \(url) on \(device.name)")

        case "erase":
            let device = try Simctl.resolveDevice(args.first)
            // simctl refuses to erase a booted device.
            _ = try? Simctl.run(["shutdown", device.udid])
            try Simctl.run(["erase", device.udid])
            print("Erased \(device.name)")

        default:
            FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
            printUsage()
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("cosmokit: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

main()
