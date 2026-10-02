//
//  AppControl.swift
//  cosmokit CLI
//
//  AGT-08: Loopback control endpoint client for CosmoKit network conditions.
//

import Foundation

public struct AppControlInfo: Codable, Equatable {
    public let pid: Int
    public let port: Int
    public let token: String
    public let version: String

    public init(pid: Int, port: Int, token: String, version: String) {
        self.pid = pid
        self.port = port
        self.token = token
        self.version = version
    }
}

public enum AppControl {
    public static var controlFileURLOverride: URL?
    public static var isPidAliveForTesting: ((Int) -> Bool)?
    public static var httpForTesting: ((URLRequest) throws -> (Data, Int))?

    public static let minimumRequiredVersion = "4.8.0"

    public static func resolveControlFileURL() -> URL? {
        if let override = controlFileURLOverride {
            return override
        }
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        // 1. Try reading bundle ID from /Applications/CosmoKit.app/Contents/Info.plist
        var bundleID = "apps.mjkweber.CosmoKit"
        let appPlistURL = URL(fileURLWithPath: "/Applications/CosmoKit.app/Contents/Info.plist")
        if let dict = NSDictionary(contentsOf: appPlistURL) as? [String: Any],
           let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty {
            bundleID = id
        }

        // 2. Sandboxed container path
        let containerURL = home
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support/CosmoKit/agent-control.json", isDirectory: false)

        if fileManager.isReadableFile(atPath: containerURL.path) {
            return containerURL
        }

        // 3. Fallback non-sandboxed path
        let standardURL = home
            .appendingPathComponent("Library/Application Support/CosmoKit/agent-control.json", isDirectory: false)
        if fileManager.isReadableFile(atPath: standardURL.path) {
            return standardURL
        }

        if fileManager.fileExists(atPath: containerURL.path) {
            return containerURL
        }

        if fileManager.fileExists(atPath: standardURL.path) {
            return standardURL
        }

        return nil
    }

    public static func readControlInfo() throws -> AppControlInfo {
        guard let url = resolveControlFileURL(),
              let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(AppControlInfo.self, from: data) else {
            throw CLIError(commandError: CommandError(
                code: .appNotRunning,
                message: "CosmoKit is not running or control file not found",
                hint: "Open CosmoKit"
            ))
        }

        // Verify PID liveness
        let isAlive: Bool
        if let customCheck = isPidAliveForTesting {
            isAlive = customCheck(info.pid)
        } else {
            isAlive = (kill(pid_t(info.pid), 0) == 0)
        }

        guard isAlive else {
            throw CLIError(commandError: CommandError(
                code: .appNotRunning,
                message: "CosmoKit process is not running (PID \(info.pid) is dead)",
                hint: "Open CosmoKit"
            ))
        }

        // Verify version >= minimumRequiredVersion
        if isVersion(info.version, olderThan: minimumRequiredVersion) {
            throw CLIError(commandError: CommandError(
                code: .appTooOld,
                message: "CosmoKit version \(info.version) is too old for network conditions",
                hint: "CosmoKit \(minimumRequiredVersion) or newer is required (found \(info.version))"
            ))
        }

        return info
    }

    public static func isVersion(_ v1: String, olderThan v2: String) -> Bool {
        let p1 = v1.split(separator: ".").compactMap { Int($0) }
        let p2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(p1.count, p2.count)
        for i in 0..<maxCount {
            let n1 = i < p1.count ? p1[i] : 0
            let n2 = i < p2.count ? p2[i] : 0
            if n1 < n2 { return true }
            if n1 > n2 { return false }
        }
        return false
    }

    public static func call(path: String, method: String = "GET", body: Data? = nil) throws -> NetworkStatusPayload {
        let info = try readControlInfo()
        guard let url = URL(string: "http://127.0.0.1:\(info.port)\(path)") else {
            throw CLIError(commandError: CommandError(code: .unsupported, message: "Invalid URL for loopback endpoint"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 5
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let statusCode: Int
        if let customHTTP = httpForTesting {
            (data, statusCode) = try customHTTP(request)
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<(Data, Int), Error>!
            URLSession.shared.dataTask(with: request) { d, r, e in
                if let e {
                    result = .failure(e)
                } else {
                    result = .success((d ?? Data(), (r as? HTTPURLResponse)?.statusCode ?? 200))
                }
                semaphore.signal()
            }.resume()
            semaphore.wait()
            (data, statusCode) = try result.get()
        }

        if statusCode == 409 {
            var hint = "Start the proxy in CosmoKit → Network"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = object["error"] as? [String: Any],
               let customHint = errorObj["hint"] as? String {
                hint = customHint
            }
            throw CLIError(commandError: CommandError(code: .proxyNotRunning, message: "CosmoKit proxy is not running", hint: hint))
        }

        guard (200...299).contains(statusCode) else {
            var message = "Control endpoint returned HTTP \(statusCode)"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = object["error"] as? [String: Any],
               let errorMsg = errorObj["message"] as? String {
                message = errorMsg
            }
            throw CLIError(commandError: CommandError(code: .driverUnavailable, message: message))
        }

        do {
            return try JSONDecoder().decode(NetworkStatusPayload.self, from: data)
        } catch {
            throw CLIError(commandError: CommandError(code: .usage, message: "Failed to decode status response: \(error.localizedDescription)"))
        }
    }

    /// Performs an authenticated request without imposing the network-status
    /// response schema. Chat routes return their own payloads.
    public static func request(path: String, method: String = "GET", body: Data? = nil,
                               timeout: TimeInterval = 5) throws -> Data {
        let info = try readControlInfo()
        guard let url = URL(string: "http://127.0.0.1:\(info.port)\(path)") else {
            throw CLIError(commandError: CommandError(code: .unsupported, message: "Invalid URL for loopback endpoint"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let statusCode: Int
        if let customHTTP = httpForTesting {
            (data, statusCode) = try customHTTP(request)
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<(Data, Int), Error>!
            URLSession.shared.dataTask(with: request) { d, response, error in
                if let error { result = .failure(error) }
                else { result = .success((d ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 200)) }
                semaphore.signal()
            }.resume()
            semaphore.wait()
            (data, statusCode) = try result.get()
        }
        guard (200...299).contains(statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Control endpoint returned HTTP \(statusCode)"
            throw CLIError(commandError: CommandError(code: statusCode == 404 ? .unsupported : .driverUnavailable, message: message))
        }
        return data
    }

    public static func status() throws -> NetworkStatusPayload {
        try call(path: "/v1/status", method: "GET")
    }

    public static func throttle(preset: String?, custom: [String: Any]?) throws -> NetworkStatusPayload {
        var payloadDict: [String: Any] = [:]
        if let preset {
            payloadDict["preset"] = preset
        } else if let custom {
            payloadDict["custom"] = custom
        }
        let bodyData = try JSONSerialization.data(withJSONObject: payloadDict)
        return try call(path: "/v1/throttle", method: "POST", body: bodyData)
    }

    public static func offline(on: Bool) throws -> NetworkStatusPayload {
        let payloadDict: [String: Any] = ["on": on]
        let bodyData = try JSONSerialization.data(withJSONObject: payloadDict)
        return try call(path: "/v1/offline", method: "POST", body: bodyData)
    }

    public static func humanText(for status: NetworkStatusPayload) -> String {
        let preset = status.conditions.preset ?? "custom"
        var details = ["preset: \(preset)"]
        if let latency = status.conditions.latencyMs, latency > 0 {
            details.append("latency: \(latency)ms")
        }
        if let down = status.conditions.downloadKbps, down > 0 {
            details.append("down: \(down)kbps")
        }
        if let up = status.conditions.uploadKbps, up > 0 {
            details.append("up: \(up)kbps")
        }
        if let pct = status.conditions.failureRatePercent, pct > 0 {
            details.append("loss: \(pct)%")
        }
        let proxyText = status.proxy.running ? "running (port \(status.proxy.port))" : "not running"
        let offlineText = status.offline ? "on" : "off"
        return "Network conditions: \(details.joined(separator: ", ")) | offline: \(offlineText) | proxy: \(proxyText)"
    }
}
