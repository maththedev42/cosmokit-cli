import Foundation

public struct DoctorCheck: Codable { public let name: String; public let ok: Bool; public let detail: String; public let hint: String?; public init(name: String, ok: Bool, detail: String, hint: String? = nil) { self.name = name; self.ok = ok; self.detail = detail; self.hint = hint } }
public struct DoctorResult: Codable { public let ok: Bool; public let checks: [DoctorCheck]; public var lines: [String] { checks.map { "\($0.ok ? "✓" : "✗") \($0.name): \($0.detail)\($0.ok ? "" : " — \($0.hint ?? "check setup")")" } }; public init(ok: Bool, checks: [DoctorCheck]) { self.ok = ok; self.checks = checks } }
public enum Doctor {
    public static func run(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = nil,
        currentDirectory: URL? = nil
    ) -> DoctorResult {
        var checks: [DoctorCheck] = []
        let xcode = FileManager.default.fileExists(atPath: "/usr/bin/xcrun"); checks.append(DoctorCheck(name: "xcode-select", ok: xcode, detail: xcode ? "available" : "missing", hint: "install Xcode command line tools"))
        let simctl = (try? Driver.runProcessForTesting("/usr/bin/xcrun", ["simctl", "list", "devices"])) != nil; checks.append(DoctorCheck(name: "simctl", ok: simctl, detail: simctl ? "responding" : "unavailable", hint: "open Xcode once and boot a simulator"))
        let booted = (try? Simctl.resolveDevice(nil)) != nil; checks.append(DoctorCheck(name: "booted simulator", ok: booted, detail: booted ? "available" : "none", hint: "cosmokit boot"))
        do {
            let root = try Driver.driverSourceRoot(environment: environment, executableURL: executableURL, currentDirectory: currentDirectory)
            checks.append(DoctorCheck(name: "driver sources", ok: true, detail: root.path))
        } catch let error as CLIError {
            checks.append(DoctorCheck(name: "driver sources", ok: false, detail: "missing", hint: error.commandError.message))
        } catch {
            checks.append(DoctorCheck(name: "driver sources", ok: false, detail: "missing", hint: error.localizedDescription))
        }
        let cache = FileManager.default.fileExists(atPath: Driver.cacheDirectory.path); checks.append(DoctorCheck(name: "driver cache", ok: cache, detail: cache ? Driver.cacheDirectory.path : "not built", hint: "cosmokit agent start"))
        let status = Driver.status(device: nil); checks.append(DoctorCheck(name: "driver", ok: status.running, detail: status.running ? "reachable" : "not running", hint: "cosmokit agent start"))
        let proxy = CLI.parseProxyStatus(CLI.proxySourceForTesting()); checks.append(DoctorCheck(name: "proxy-status", ok: true, detail: CLI.proxyHumanText(proxy)))
        return DoctorResult(ok: checks.filter { $0.name != "proxy-status" }.allSatisfy(\.ok), checks: checks)
    }
}
