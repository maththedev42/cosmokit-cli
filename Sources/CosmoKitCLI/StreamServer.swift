import Foundation
import Network
import CoreGraphics
import ImageIO

public protocol DriverClientType {
    func status(device: String?) -> DriverStatusPayload
    func call(_ path: String, method: String, json: [String: Any]?) throws -> Data
}

public struct DefaultDriverClient: DriverClientType {
    public init() {}
    public func status(device: String?) -> DriverStatusPayload {
        Driver.status(device: device)
    }
    public func call(_ path: String, method: String, json: [String: Any]?) throws -> Data {
        try Driver.call(path, method: method, json: json)
    }
}

public final class StreamServer {
    public static var driverClient: DriverClientType = DefaultDriverClient()

    public let port: Int
    public let token: String
    public let device: Device
    public let fps: Double
    public let scale: Double
    public let source: String
    public let branch: String?
    public let worktree: String?
    public let appBundleID: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cosmokit.stream", qos: .userInteractive)
    private var isRunning = false
    private var latestFrameData: Data?
    private var frameLock = NSLock()

    public init(port: Int = 8878,
                token: String = StreamServer.generateToken(),
                device: Device,
                fps: Double = 4.0,
                scale: Double = 0.5,
                source: String = "simctl",
                branch: String? = nil,
                worktree: String? = nil,
                appBundleID: String? = nil) {
        self.port = port
        self.token = token
        self.device = device
        self.fps = fps
        self.scale = scale
        self.source = source
        self.branch = branch ?? StreamServer.detectGitBranch()
        self.worktree = worktree ?? StreamServer.detectGitWorktree()
        self.appBundleID = appBundleID
    }

    public static func generateToken() -> String {
        let chars = "0123456789abcdef"
        return String((0..<12).compactMap { _ in chars.randomElement() })
    }

    public var url: String {
        "http://127.0.0.1:\(port)/s/\(token)/"
    }

    public static func pidFile(for udid: String) -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cosmokit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stream-\(udid).json")
    }

    public static func stop(device query: String?) throws -> DriverActionPayload {
        let device = try Simctl.resolveDevice(query)
        let file = pidFile(for: device.udid)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int else {
            return DriverActionPayload(ok: true, message: "No stream running for \(device.name)")
        }
        kill(pid_t(pid), SIGTERM)
        try? FileManager.default.removeItem(at: file)
        return DriverActionPayload(ok: true, message: "Stopped stream on \(device.name)")
    }

    public static func status(device query: String?) -> StreamStatusPayload {
        guard let device = try? Simctl.resolveDevice(query) else {
            return StreamStatusPayload(running: false, port: nil, pid: nil, url: nil)
        }
        let file = pidFile(for: device.udid)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int,
              let port = json["port"] as? Int,
              let token = json["token"] as? String else {
            return StreamStatusPayload(running: false, port: nil, pid: nil, url: nil)
        }
        // Check if process is still alive
        if kill(pid_t(pid), 0) == 0 {
            return StreamStatusPayload(running: true, port: port, pid: pid, url: "http://127.0.0.1:\(port)/s/\(token)/")
        } else {
            try? FileManager.default.removeItem(at: file)
            return StreamStatusPayload(running: false, port: nil, pid: nil, url: nil)
        }
    }

    public func start(openBrowser: Bool = false) throws {
        let endpoint = NWEndpoint.Port(rawValue: UInt16(port))!
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: endpoint)
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
            case .failed(let err):
                self.isRunning = false
                FileHandle.standardError.write(Data("Stream server failed: \(err)\n".utf8))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handleConnection(connection)
        }

        listener.start(queue: queue)

        // Write pid file
        let pidInfo: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "port": port,
            "token": token,
            "udid": device.udid
        ]
        if let data = try? JSONSerialization.data(withJSONObject: pidInfo) {
            try? data.write(to: StreamServer.pidFile(for: device.udid))
        }

        // Start background frame capture loop
        startFrameCaptureLoop()

        if openBrowser {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url]
            try? process.run()
        }
    }

    private func startFrameCaptureLoop() {
        queue.async { [weak self] in
            guard let self else { return }
            let interval = 1.0 / max(1.0, self.fps)
            while self.isRunning {
                let start = Date()
                if let frame = self.captureFrame() {
                    self.frameLock.lock()
                    self.latestFrameData = frame
                    self.frameLock.unlock()
                }
                let elapsed = Date().timeIntervalSince(start)
                let remaining = interval - elapsed
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: remaining)
                }
            }
        }
    }

    public func captureFrame() -> Data? {
        if source == "driver" {
            if let data = try? Driver.call("/screenshot") {
                return scaleImage(data: data, factor: scale)
            }
        }
        // simctl fallback
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let tempFile = tempDir.appendingPathComponent("cosmokit-stream-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        do {
            _ = try Simctl.run(["io", device.udid, "screenshot", tempFile.path])
            if let rawData = try? Data(contentsOf: tempFile) {
                return scaleImage(data: rawData, factor: scale)
            }
        } catch {
            return nil
        }
        return nil
    }

    public func getLatestFrame() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        if let data = latestFrameData { return data }
        let frame = captureFrame()
        latestFrameData = frame
        return frame
    }

    public func triggerImmediateFrameCapture() {
        queue.async { [weak self] in
            guard let self else { return }
            if let frame = self.captureFrame() {
                self.frameLock.lock()
                self.latestFrameData = frame
                self.frameLock.unlock()
            }
        }
    }

    private func scaleImage(data: Data, factor: Double) -> Data {
        guard factor < 1.0, factor > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data
        }
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return data
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return data }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.png" as CFString, 1, nil) else {
            return data
        }
        CGImageDestinationAddImage(dest, scaled, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPRequest(from: connection)
    }

    private func readHTTPRequest(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, let data = content, error == nil else {
                connection.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                self.sendResponse(connection: connection, status: 400, headers: [:], body: Data())
                return
            }

            let lines = requestString.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                self.sendResponse(connection: connection, status: 400, headers: [:], body: Data())
                return
            }

            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                self.sendResponse(connection: connection, status: 400, headers: [:], body: Data())
                return
            }

            let method = parts[0]
            let uri = parts[1]

            // Extract body if present
            var bodyData: Data? = nil
            if let bodyRange = requestString.range(of: "\r\n\r\n") {
                let bodyString = String(requestString[bodyRange.upperBound...])
                bodyData = bodyString.data(using: .utf8)
            }

            if uri == "/s/\(self.token)/stream.mjpeg" {
                self.handleMJPEGStream(connection: connection)
                return
            }

            let response = StreamServer.processRequest(
                method: method,
                uri: uri,
                body: bodyData,
                token: self.token,
                udid: self.device.udid,
                deviceName: self.device.name,
                branch: self.branch,
                worktree: self.worktree,
                app: self.appBundleID,
                frameProvider: { self.getLatestFrame() },
                scale: self.scale,
                onPostAct: { [weak self] in self?.triggerImmediateFrameCapture() }
            )

            self.sendResponse(connection: connection, status: response.statusCode, headers: response.headers, body: response.body)
        }
    }

    private func handleMJPEGStream(connection: NWConnection) {
        let boundary = "frame"
        let header = "HTTP/1.1 200 OK\r\nConnection: close\r\nServer: cosmokit\r\nCache-Control: no-cache, private\r\nContent-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed({ _ in }))

        let interval = 1.0 / max(1.0, self.fps)
        func sendNextFrame() {
            guard self.isRunning else {
                connection.cancel()
                return
            }
            if let frame = self.getLatestFrame() {
                var part = "--\(boundary)\r\n"
                part += "Content-Type: image/png\r\n"
                part += "Content-Length: \(frame.count)\r\n\r\n"
                var chunk = Data(part.utf8)
                chunk.append(frame)
                chunk.append(contentsOf: Data("\r\n".utf8))
                connection.send(content: chunk, completion: .contentProcessed({ [weak self] error in
                    if error != nil {
                        connection.cancel()
                        return
                    }
                    self?.queue.asyncAfter(deadline: .now() + interval) {
                        sendNextFrame()
                    }
                }))
            } else {
                self.queue.asyncAfter(deadline: .now() + interval) {
                    sendNextFrame()
                }
            }
        }
        sendNextFrame()
    }

    private func sendResponse(connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 400 ? "Bad Request" : "Internal Server Error"))
        var head = "HTTP/1.1 \(status) \(statusText)\r\nContent-Length: \(body.count)\r\nServer: cosmokit\r\n"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    // Static request processing for deterministic testing without sockets
    public static func processRequest(method: String,
                                      uri: String,
                                      body: Data?,
                                      token: String,
                                      udid: String,
                                      deviceName: String = "iPhone",
                                      branch: String? = nil,
                                      worktree: String? = nil,
                                      app: String? = nil,
                                      frameProvider: () -> Data? = { nil },
                                      scale: Double = 0.5,
                                      onPostAct: () -> Void = {}) -> (statusCode: Int, headers: [String: String], body: Data) {
        let prefix = "/s/\(token)"
        guard uri.hasPrefix(prefix) else {
            return (404, ["Content-Type": "text/plain"], Data("Not Found\n".utf8))
        }

        let subpath = String(uri.dropFirst(prefix.count))
        let pathOnly = subpath.split(separator: "?").first.map(String.init) ?? subpath
        let query = subpath.contains("?") ? String(subpath.split(separator: "?")[1]) : ""

        switch (method, pathOnly) {
        case ("GET", ""), ("GET", "/"):
            let html = renderHTMLPage(token: token, deviceName: deviceName, udid: udid, branch: branch, worktree: worktree, app: app)
            return (200, ["Content-Type": "text/html; charset=utf-8"], Data(html.utf8))

        case ("GET", "/frame.png"):
            if let frame = frameProvider() {
                return (200, ["Content-Type": "image/png"], frame)
            }
            return (404, ["Content-Type": "text/plain"], Data("No frame available\n".utf8))

        case ("GET", "/tree"):
            let driverStatus = driverClient.status(device: udid)
            if !driverStatus.running {
                let err = "{\"ok\":false,\"error\":{\"code\":\"driverUnavailable\",\"message\":\"Driver is not running. Start it with: cosmokit agent start\"}}"
                return (200, ["Content-Type": "application/json"], Data(err.utf8))
            }
            if let data = try? driverClient.call("/tree", method: "GET", json: nil) {
                return (200, ["Content-Type": "application/json"], data)
            }
            let err = "{\"ok\":false,\"error\":{\"code\":\"driverUnavailable\",\"message\":\"Driver unavailable\"}}"
            return (200, ["Content-Type": "application/json"], Data(err.utf8))

        case ("POST", "/act"):
            let driverStatus = driverClient.status(device: udid)
            if !driverStatus.running {
                let err = "{\"ok\":false,\"error\":{\"code\":\"driverUnavailable\",\"message\":\"Driver is not running. Start it with: cosmokit agent start\"}}"
                return (200, ["Content-Type": "application/json"], Data(err.utf8))
            }

            guard let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let action = json["action"] as? String else {
                return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"Missing action\"}}".utf8))
            }

            switch action {
            case "tap":
                guard let pageX = (json["x"] as? Double) ?? (json["x"] as? Int).map(Double.init),
                      let pageY = (json["y"] as? Double) ?? (json["y"] as? Int).map(Double.init) else {
                    return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"tap requires x and y coordinates\"}}".utf8))
                }
                let ptX = pageX / max(0.1, scale)
                let ptY = pageY / max(0.1, scale)
                do {
                    _ = try driverClient.call("/tap", method: "POST", json: ["x": ptX, "y": ptY])
                    onPostAct()
                    return (200, ["Content-Type": "application/json"], Data("{\"ok\":true}".utf8))
                } catch {
                    return (500, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"driverError\",\"message\":\"\(error.localizedDescription)\"}}".utf8))
                }

            case "swipe":
                guard let pageX1 = (json["x1"] as? Double) ?? (json["x1"] as? Int).map(Double.init),
                      let pageY1 = (json["y1"] as? Double) ?? (json["y1"] as? Int).map(Double.init),
                      let pageX2 = (json["x2"] as? Double) ?? (json["x2"] as? Int).map(Double.init),
                      let pageY2 = (json["y2"] as? Double) ?? (json["y2"] as? Int).map(Double.init) else {
                    return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"swipe requires x1, y1, x2, and y2 coordinates\"}}".utf8))
                }
                let ptX1 = pageX1 / max(0.1, scale)
                let ptY1 = pageY1 / max(0.1, scale)
                let ptX2 = pageX2 / max(0.1, scale)
                let ptY2 = pageY2 / max(0.1, scale)
                var swipeJson: [String: Any] = [
                    "x1": ptX1, "y1": ptY1,
                    "x2": ptX2, "y2": ptY2,
                    "from": ["x": ptX1, "y": ptY1],
                    "to": ["x": ptX2, "y": ptY2]
                ]
                if let duration = (json["duration"] as? Double) ?? (json["duration"] as? Int).map(Double.init) {
                    swipeJson["duration"] = duration
                }
                do {
                    _ = try driverClient.call("/swipe", method: "POST", json: swipeJson)
                    onPostAct()
                    return (200, ["Content-Type": "application/json"], Data("{\"ok\":true}".utf8))
                } catch {
                    return (500, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"driverError\",\"message\":\"\(error.localizedDescription)\"}}".utf8))
                }

            case "type":
                guard let text = json["text"] as? String else {
                    return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"type requires text\"}}".utf8))
                }
                let capped = String(text.prefix(2000))
                do {
                    _ = try driverClient.call("/type", method: "POST", json: ["text": capped])
                    onPostAct()
                    return (200, ["Content-Type": "application/json"], Data("{\"ok\":true}".utf8))
                } catch {
                    return (500, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"driverError\",\"message\":\"\(error.localizedDescription)\"}}".utf8))
                }

            case "button":
                guard let name = json["name"] as? String else {
                    return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"button requires name\"}}".utf8))
                }
                let allowed: Set<String> = ["home", "lock", "siri", "volumeUp", "volumeDown", "volume-up", "volume-down"]
                guard allowed.contains(name) else {
                    return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"Invalid button name: \(name)\"}}".utf8))
                }
                do {
                    _ = try driverClient.call("/button", method: "POST", json: ["name": name])
                    onPostAct()
                    return (200, ["Content-Type": "application/json"], Data("{\"ok\":true}".utf8))
                } catch {
                    return (500, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"driverError\",\"message\":\"\(error.localizedDescription)\"}}".utf8))
                }

            default:
                return (400, ["Content-Type": "application/json"], Data("{\"ok\":false,\"error\":{\"code\":\"badAction\",\"message\":\"Unknown action: \(action)\"}}".utf8))
            }

        case ("POST", "/feedback"):
            guard let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let pageX = json["x"] as? Double,
                  let pageY = json["y"] as? Double,
                  let text = json["text"] as? String else {
                return (400, ["Content-Type": "application/json"], Data("{\"error\":\"Invalid feedback payload\"}".utf8))
            }

            // Convert page pixels to points based on scale factor
            // In stream view, page pixels = rendered pixels * scale
            // Simulator points = page pixels / (scale * 2.0 or 3.0 ratio)
            // If scale is e.g. 0.5, point = pageCoord / scale / (scaleFactor)
            let ptX = pageX / max(0.1, scale)
            let ptY = pageY / max(0.1, scale)

            // Resolve element from fresh debug tree
            var element = FeedbackElementPayload(ref: 0, type: "View", label: nil, identifier: nil, frame: nil)
            if let treeData = try? driverClient.call("/tree", method: "GET", json: nil),
               let snapshot = try? UITree.parse(treeData) {
                // Determine scale between raw screenshot points and tree frame points if needed
                if let resolved = FeedbackStore.resolveElement(in: snapshot, x: ptX, y: ptY) ?? FeedbackStore.resolveElement(in: snapshot, x: pageX, y: pageY) {
                    element = FeedbackElementPayload(
                        ref: resolved.ref,
                        type: resolved.type,
                        label: resolved.label,
                        identifier: resolved.identifier,
                        frame: resolved.frame
                    )
                }
            }

            // Save frame PNG to disk
            let dir = FeedbackStore.feedbackDirectory(for: udid)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let existing = FeedbackStore.readAll(udid: udid)
            let seq = (existing.map(\.seq).max() ?? 0) + 1
            let frameFile = dir.appendingPathComponent("\(seq).png")
            if let currentFrame = frameProvider() {
                try? currentFrame.write(to: frameFile)
            }

            // Append record
            do {
                let record = try FeedbackStore.append(
                    udid: udid,
                    x: ptX,
                    y: ptY,
                    element: element,
                    text: text,
                    framePath: frameFile.path,
                    branch: branch,
                    worktree: worktree,
                    app: app
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let recordData = try encoder.encode(record)
                return (200, ["Content-Type": "application/json"], recordData)
            } catch {
                return (500, ["Content-Type": "application/json"], Data("{\"error\":\"Could not save feedback\"}".utf8))
            }

        case ("GET", "/feedback"):
            var since = 0
            var wait = 0.0
            for param in query.components(separatedBy: "&") {
                let pair = param.components(separatedBy: "=")
                if pair.count == 2 {
                    if pair[0] == "since", let val = Int(pair[1]) { since = val }
                    if pair[0] == "wait", let val = Double(pair[1]) { wait = min(300.0, val) }
                }
            }
            let start = Date()
            while true {
                let records = FeedbackStore.readAll(udid: udid).filter { $0.seq > since }
                if !records.isEmpty || wait <= 0 || Date().timeIntervalSince(start) >= wait {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = (try? encoder.encode(FeedbackListPayload(records: records))) ?? Data("{\"records\":[]}".utf8)
                    return (200, ["Content-Type": "application/json"], data)
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

        case ("GET", "/feedback/prompt"):
            var seq: Int? = nil
            var scope = "unacked"
            for param in query.components(separatedBy: "&") {
                let pair = param.components(separatedBy: "=")
                if pair.count == 2 {
                    if pair[0] == "seq", let val = Int(pair[1]) { seq = val }
                    if pair[0] == "scope" { scope = pair[1] }
                }
            }
            let records = FeedbackStore.readAll(udid: udid)
            let selectedRecords: [FeedbackRecordPayload]
            if let seq = seq {
                guard let target = records.first(where: { $0.seq == seq }) else {
                    return (404, ["Content-Type": "text/plain; charset=utf-8"], Data("no feedback record with seq #\(seq)\n".utf8))
                }
                selectedRecords = [target]
            } else if scope == "all" {
                selectedRecords = records
            } else {
                selectedRecords = records.filter { ($0.acked ?? false) == false }
            }
            let text = FeedbackPrompt.render(selectedRecords, app: app)
            return (200, ["Content-Type": "text/plain; charset=utf-8"], Data(text.utf8))

        default:
            // Check for /feedback/<seq>/ack
            if method == "POST" && pathOnly.hasPrefix("/feedback/") && pathOnly.hasSuffix("/ack") {
                let stripped = pathOnly.replacingOccurrences(of: "/feedback/", with: "").replacingOccurrences(of: "/ack", with: "")
                if let seq = Int(stripped) {
                    if let updated = try? FeedbackStore.ack(udid: udid, seq: seq) {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        let data = (try? encoder.encode(updated)) ?? Data()
                        return (200, ["Content-Type": "application/json"], data)
                    }
                }
                return (404, ["Content-Type": "application/json"], Data("{\"error\":\"Record not found\"}".utf8))
            }
            return (404, ["Content-Type": "text/plain"], Data("Not Found\n".utf8))
        }
    }

    private static func detectGitBranch() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let branch = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branch?.isEmpty == false) ? branch : nil
    }

    private static func detectGitWorktree() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let worktree = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (worktree?.isEmpty == false) ? worktree : nil
    }

    private static func renderHTMLPage(token: String,
                                       deviceName: String,
                                       udid: String,
                                       branch: String?,
                                       worktree: String?,
                                       app: String?) -> String {
        return #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CosmoKit Stream — \#(deviceName)</title>
<style>
  :root {
    --bg: #0d1117;
    --card: #161b22;
    --border: #30363d;
    --text: #c9d1d9;
    --text-dim: #8b949e;
    --accent: #58a6ff;
    --green: #3fb950;
    --red: #f85149;
    --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font);
    display: flex;
    flex-direction: column;
    height: 100vh;
    overflow: hidden;
  }
  header {
    background: var(--card);
    border-bottom: 1px solid var(--border);
    padding: 10px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 13px;
  }
  .header-left { display: flex; gap: 12px; align-items: center; }
  .badge { background: #21262d; border: 1px solid var(--border); border-radius: 4px; padding: 2px 8px; font-weight: 600; font-size: 12px; }
  .badge.device { color: var(--accent); }
  .mode-toggle {
    display: flex;
    background: #0d1117;
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 2px;
    gap: 2px;
  }
  .mode-btn {
    padding: 4px 14px;
    background: transparent;
    border: none;
    border-radius: 4px;
    color: var(--text-dim);
    font-weight: 600;
    cursor: pointer;
    font-size: 12px;
    transition: all 0.15s ease;
  }
  .mode-btn.active {
    background: var(--accent);
    color: #fff;
  }
  .main-container {
    display: flex;
    flex: 1;
    overflow: hidden;
  }
  .stream-panel {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 16px;
    position: relative;
    background: #010409;
  }
  .act-status {
    position: absolute;
    top: 20px;
    background: rgba(22, 27, 34, 0.95);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 6px 16px;
    border-radius: 20px;
    font-size: 12px;
    font-family: ui-monospace, SFMono-Regular, monospace;
    pointer-events: none;
    z-index: 100;
    box-shadow: 0 4px 12px rgba(0,0,0,0.5);
    transition: opacity 0.2s ease-in-out;
  }
  .act-status.error {
    border-color: var(--red);
    color: var(--red);
  }
  .frame-wrapper {
    position: relative;
    display: inline-block;
    cursor: crosshair;
    box-shadow: 0 8px 24px rgba(0,0,0,0.5);
    border-radius: 8px;
    overflow: hidden;
    user-select: none;
  }
  .frame-wrapper:focus {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
  }
  #streamFrame {
    display: block;
    max-height: calc(100vh - 120px);
    max-width: 100%;
    object-fit: contain;
    user-select: none;
    -webkit-user-drag: none;
  }
  .crosshair {
    position: absolute;
    width: 20px;
    height: 20px;
    border: 2px solid var(--accent);
    border-radius: 50%;
    transform: translate(-50%, -50%);
    pointer-events: none;
    display: none;
    box-shadow: 0 0 8px rgba(88, 166, 255, 0.8);
    z-index: 10;
  }
  .drag-overlay {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
    display: none;
    z-index: 20;
  }
  .side-panel {
    width: 380px;
    background: var(--card);
    border-left: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .tabs {
    display: flex;
    border-bottom: 1px solid var(--border);
  }
  .tab-btn {
    flex: 1;
    padding: 10px;
    background: transparent;
    border: none;
    color: var(--text-dim);
    font-weight: 600;
    cursor: pointer;
    font-size: 13px;
  }
  .tab-btn.active {
    color: var(--text);
    border-bottom: 2px solid var(--accent);
  }
  .panel-content {
    flex: 1;
    overflow-y: auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  .feedback-box {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 12px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .element-info {
    font-size: 12px;
    color: var(--text-dim);
    background: #21262d;
    padding: 6px 8px;
    border-radius: 4px;
    font-family: ui-monospace, SFMono-Regular, monospace;
  }
  textarea {
    width: 100%;
    height: 70px;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 8px;
    color: var(--text);
    font-family: inherit;
    font-size: 13px;
    resize: none;
  }
  textarea:focus { outline: 1px solid var(--accent); }
  button.submit-btn {
    background: #238636;
    color: #fff;
    border: none;
    border-radius: 4px;
    padding: 8px 12px;
    font-weight: 600;
    cursor: pointer;
    font-size: 13px;
  }
  button.submit-btn:hover { background: #2ea043; }
  .hw-buttons {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 4px;
  }
  .hw-btn {
    flex: 1 1 calc(33.3% - 8px);
    background: #21262d;
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 8px 6px;
    color: var(--text);
    font-weight: 600;
    font-size: 12px;
    cursor: pointer;
    text-align: center;
    transition: background 0.1s;
  }
  .hw-btn:hover { background: #30363d; }
  .control-hints {
    font-size: 12px;
    color: var(--text-dim);
    line-height: 1.6;
  }
  .comment-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .comment-card {
    background: var(--bg);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    font-size: 13px;
  }
  .comment-header {
    display: flex;
    justify-content: space-between;
    font-size: 11px;
    color: var(--text-dim);
  }
  .comment-ack {
    cursor: pointer;
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 3px;
    border: 1px solid var(--border);
  }
  .comment-ack.acked { color: var(--green); border-color: var(--green); }
  .copy-btn {
    background: #21262d;
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 2px 8px;
    color: var(--text);
    font-size: 11px;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease;
  }
  .copy-btn:hover { background: #30363d; }
  .copy-btn.copied { color: var(--green); border-color: var(--green); }
  pre#treeOutput {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 11px;
    line-height: 1.4;
    white-space: pre-wrap;
    word-break: break-word;
  }
</style>
</head>
<body>
  <header>
    <div class="header-left">
      <span class="badge device">\#(deviceName)</span>
      <span style="color:var(--text-dim);">\#(udid)</span>
      \#(app != nil ? "<span class=\"badge\">App: " + app! + "</span>" : "")
      \#(branch != nil ? "<span class=\"badge\">Git: " + branch! + "</span>" : "")
    </div>
    <div class="mode-toggle">
      <button class="mode-btn active" id="btnFeedbackMode" onclick="setMode('feedback')">Feedback</button>
      <button class="mode-btn" id="btnControlMode" onclick="setMode('control')">Control</button>
    </div>
    <div class="header-right">
      <span style="color:var(--text-dim); font-size:12px;">127.0.0.1:\#(token)</span>
    </div>
  </header>

  <div class="main-container">
    <div class="stream-panel">
      <div class="act-status" id="actStatus" style="display:none;"></div>
      <div class="frame-wrapper" id="frameWrapper" tabindex="0">
        <img id="streamFrame" src="/s/\#(token)/stream.mjpeg" alt="Simulator Frame" onerror="this.src='/s/\#(token)/frame.png'">
        <div class="crosshair" id="crosshair"></div>
        <svg class="drag-overlay" id="dragOverlay">
          <line id="dragLine" x1="0" y1="0" x2="0" y2="0" stroke="#58a6ff" stroke-width="2" stroke-linecap="round" stroke-dasharray="4 2" />
        </svg>
      </div>
    </div>

    <div class="side-panel">
      <div class="tabs" id="tabsBar">
        <button class="tab-btn active" id="tabMainBtn" onclick="showTab('main')">Feedback</button>
        <button class="tab-btn" id="tabTreeBtn" onclick="showTab('tree')">UI Tree</button>
      </div>

      <div class="panel-content" id="controlBox" style="display:none;">
        <div class="feedback-box">
          <div style="font-weight:600; font-size:12px;">Hardware Buttons</div>
          <div class="hw-buttons">
            <button class="hw-btn" onclick="sendButton('home')">Home</button>
            <button class="hw-btn" onclick="sendButton('lock')">Lock</button>
            <button class="hw-btn" onclick="sendButton('volume-up')">Vol +</button>
            <button class="hw-btn" onclick="sendButton('volume-down')">Vol −</button>
            <button class="hw-btn" onclick="sendButton('siri')">Siri</button>
          </div>
        </div>
        <div class="feedback-box">
          <div style="font-weight:600; font-size:12px;">Interactions</div>
          <div class="control-hints">
            <div>• <strong>Click</strong> to tap</div>
            <div>• <strong>Drag (&gt;12px)</strong> to swipe</div>
            <div>• <strong>Focus &amp; Type</strong> to send keystrokes</div>
            <div>• <strong>Enter</strong> sends Return (\n)</div>
          </div>
        </div>
      </div>

      <div class="panel-content" id="feedbackTab">
        <div class="feedback-box">
          <div style="font-weight:600; font-size:12px;">Click simulator frame to comment:</div>
          <div class="element-info" id="selectedElement">No element selected. Click on the frame to point to an element.</div>
          <textarea id="commentText" placeholder="Describe feedback for the AI agent..."></textarea>
          <button class="submit-btn" id="sendBtn" onclick="submitFeedback()">Send to agent</button>
        </div>

        <div style="display:flex; justify-content:space-between; align-items:center; margin-top:8px;">
          <span style="font-weight:600; font-size:12px;">Recent Comments</span>
          <button class="copy-btn" id="copyAllUnackedBtn" onclick="copyPrompt('unacked', this)">Copy all unacked</button>
        </div>
        <div class="comment-list" id="commentList"></div>
      </div>

      <div class="panel-content" id="treeTab" style="display:none;">
        <button class="submit-btn" style="background:#21262d; border:1px solid var(--border);" onclick="refreshTree()">Refresh Tree</button>
        <pre id="treeOutput">Loading tree...</pre>
      </div>
    </div>
  </div>

  <script>
    const token = "\#(token)";
    let currentMode = "feedback";
    let selectedPoint = { x: 0, y: 0 };
    let highestSeq = 0;

    let isMouseDown = false;
    let dragStartX = 0, dragStartY = 0;
    let dragStartPageX = 0, dragStartPageY = 0;
    let typeBuffer = "";
    let typeTimer = null;
    let actStatusTimer = null;

    const frameWrapper = document.getElementById("frameWrapper");
    const streamFrame = document.getElementById("streamFrame");
    const crosshair = document.getElementById("crosshair");
    const selectedElementDiv = document.getElementById("selectedElement");
    const commentListDiv = document.getElementById("commentList");
    const actStatusDiv = document.getElementById("actStatus");

    function setMode(mode) {
      currentMode = mode;
      document.getElementById("btnFeedbackMode").classList.toggle("active", mode === "feedback");
      document.getElementById("btnControlMode").classList.toggle("active", mode === "control");
      document.getElementById("tabMainBtn").textContent = mode === "control" ? "Controls" : "Feedback";

      if (mode === "control") {
        frameWrapper.style.cursor = "pointer";
        crosshair.style.display = "none";
        document.getElementById("feedbackTab").style.display = "none";
        document.getElementById("controlBox").style.display = "flex";
        document.getElementById("treeTab").style.display = "none";
        document.getElementById("tabMainBtn").classList.add("active");
        document.getElementById("tabTreeBtn").classList.remove("active");
        frameWrapper.focus();
        showStatus("Control mode active");
      } else {
        frameWrapper.style.cursor = "crosshair";
        document.getElementById("controlBox").style.display = "none";
        document.getElementById("feedbackTab").style.display = "flex";
        document.getElementById("treeTab").style.display = "none";
        document.getElementById("tabMainBtn").classList.add("active");
        document.getElementById("tabTreeBtn").classList.remove("active");
        document.getElementById("dragOverlay").style.display = "none";
      }
    }

    function showStatus(msg, isError = false) {
      actStatusDiv.textContent = msg;
      actStatusDiv.className = isError ? "act-status error" : "act-status";
      actStatusDiv.style.display = "block";
      clearTimeout(actStatusTimer);
      actStatusTimer = setTimeout(() => {
        actStatusDiv.style.display = "none";
      }, 2000);
    }

    function getCoords(e) {
      const rect = streamFrame.getBoundingClientRect();
      const clientX = e.clientX - rect.left;
      const clientY = e.clientY - rect.top;
      const naturalW = streamFrame.naturalWidth || rect.width;
      const naturalH = streamFrame.naturalHeight || rect.height;
      const scaleX = naturalW / rect.width;
      const scaleY = naturalH / rect.height;
      return {
        localX: clientX,
        localY: clientY,
        pageX: clientX * scaleX,
        pageY: clientY * scaleY
      };
    }

    async function sendAct(payload) {
      try {
        const res = await fetch(`/s/${token}/act`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload)
        });
        const data = await res.json();
        if (res.ok && data.ok) {
          if (payload.action === "tap") {
            showStatus(`Tap (${Math.round(payload.x)}, ${Math.round(payload.y)}) ✓`);
          } else if (payload.action === "swipe") {
            showStatus("Swipe ✓");
          } else if (payload.action === "type") {
            showStatus(`Type "${payload.text.replace(/\n/g, "\\n")}" ✓`);
          } else if (payload.action === "button") {
            showStatus(`Button ${payload.name} ✓`);
          } else {
            showStatus("Action ✓");
          }
        } else {
          const code = (data.error && data.error.code) || "error";
          showStatus(`${payload.action} failed: ${code}`, true);
        }
      } catch (err) {
        showStatus(`${payload.action} failed: network error`, true);
      }
    }

    async function sendButton(name) {
      await sendAct({ action: "button", name: name });
    }

    // Feedback click handler
    streamFrame.addEventListener("click", (e) => {
      if (currentMode !== "feedback") return;
      const coords = getCoords(e);
      selectedPoint = { x: coords.pageX, y: coords.pageY };

      crosshair.style.left = coords.localX + "px";
      crosshair.style.top = coords.localY + "px";
      crosshair.style.display = "block";

      selectedElementDiv.textContent = `Point: (${Math.round(coords.pageX)}, ${Math.round(coords.pageY)}) — Type comment below`;
      document.getElementById("commentText").focus();
    });

    // Control mousedown/mousemove/mouseup for tap & swipe
    streamFrame.addEventListener("mousedown", (e) => {
      if (currentMode !== "control") return;
      e.preventDefault();
      frameWrapper.focus();
      isMouseDown = true;
      const coords = getCoords(e);
      dragStartX = coords.localX;
      dragStartY = coords.localY;
      dragStartPageX = coords.pageX;
      dragStartPageY = coords.pageY;
    });

    window.addEventListener("mousemove", (e) => {
      if (currentMode !== "control" || !isMouseDown) return;
      const rect = streamFrame.getBoundingClientRect();
      const currX = e.clientX - rect.left;
      const currY = e.clientY - rect.top;
      const dist = Math.hypot(currX - dragStartX, currY - dragStartY);
      const overlay = document.getElementById("dragOverlay");
      const line = document.getElementById("dragLine");
      if (dist > 12) {
        overlay.style.display = "block";
        line.setAttribute("x1", dragStartX);
        line.setAttribute("y1", dragStartY);
        line.setAttribute("x2", currX);
        line.setAttribute("y2", currY);
      } else {
        overlay.style.display = "none";
      }
    });

    window.addEventListener("mouseup", (e) => {
      if (currentMode !== "control" || !isMouseDown) return;
      isMouseDown = false;
      document.getElementById("dragOverlay").style.display = "none";
      const coords = getCoords(e);
      const dist = Math.hypot(coords.localX - dragStartX, coords.localY - dragStartY);
      if (dist > 12) {
        sendAct({
          action: "swipe",
          x1: dragStartPageX,
          y1: dragStartPageY,
          x2: coords.pageX,
          y2: coords.pageY
        });
      } else {
        sendAct({
          action: "tap",
          x: coords.pageX,
          y: coords.pageY
        });
      }
    });

    // Keydown debounced typing in Control mode
    frameWrapper.addEventListener("keydown", (e) => {
      if (currentMode !== "control") return;
      if (e.key === "Enter") {
        e.preventDefault();
        typeBuffer += "\n";
        resetTypeTimer();
      } else if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        typeBuffer += e.key;
        resetTypeTimer();
      }
      // Note: Backspace is not supported by driver /type and is ignored.
    });

    function resetTypeTimer() {
      clearTimeout(typeTimer);
      typeTimer = setTimeout(() => {
        if (typeBuffer.length > 0) {
          const text = typeBuffer;
          typeBuffer = "";
          sendAct({ action: "type", text: text });
        }
      }, 300);
    }

    async function submitFeedback() {
      const text = document.getElementById("commentText").value.trim();
      if (!text) return;

      const btn = document.getElementById("sendBtn");
      btn.disabled = true;
      btn.textContent = "Sending...";

      try {
        const res = await fetch(`/s/${token}/feedback`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ x: selectedPoint.x, y: selectedPoint.y, text: text })
        });
        if (res.ok) {
          const rec = await res.json();
          document.getElementById("commentText").value = "";
          addCommentCard(rec, true);
          selectedElementDiv.textContent = `Comment #${rec.seq} sent to agent!`;
        }
      } catch (err) {
        alert("Error sending feedback: " + err);
      } finally {
        btn.disabled = false;
        btn.textContent = "Send to agent";
      }
    }

    async function toggleAck(seq) {
      try {
        const res = await fetch(`/s/${token}/feedback/${seq}/ack`, { method: "POST" });
        if (res.ok) {
          const updated = await res.json();
          const badge = document.getElementById(`ack-${seq}`);
          if (badge) {
            badge.className = updated.acked ? "comment-ack acked" : "comment-ack";
            badge.textContent = updated.acked ? "✓ Answered" : "Pending";
          }
        }
      } catch (e) {}
    }

    function addCommentCard(rec, prepend = false) {
      if (document.getElementById(`comment-${rec.seq}`)) return;
      if (rec.seq > highestSeq) highestSeq = rec.seq;

      const card = document.createElement("div");
      card.className = "comment-card";
      card.id = `comment-${rec.seq}`;
      const elem = rec.element || {};
      const elemDesc = elem.type ? `[${elem.ref}] ${elem.type}${elem.label ? ' "' + elem.label + '"' : ''}` : `Point (${Math.round(rec.x)}, ${Math.round(rec.y)})`;

      card.innerHTML = `
        <div class="comment-header">
          <span>#${rec.seq} • ${elemDesc}</span>
          <div style="display:flex; gap:6px; align-items:center;">
            <button class="copy-btn" onclick="copyPrompt(${rec.seq}, this)">Copy prompt</button>
            <span class="${rec.acked ? 'comment-ack acked' : 'comment-ack'}" id="ack-${rec.seq}" onclick="toggleAck(${rec.seq})">
              ${rec.acked ? '✓ Answered' : 'Pending'}
            </span>
          </div>
        </div>
        <div style="font-weight:500;">${rec.text}</div>
      `;
      if (prepend && commentListDiv.firstChild) {
        commentListDiv.insertBefore(card, commentListDiv.firstChild);
      } else {
        commentListDiv.appendChild(card);
      }
    }

    async function pollFeedback() {
      try {
        const res = await fetch(`/s/${token}/feedback?since=${highestSeq}&wait=15`);
        if (res.ok) {
          const data = await res.json();
          (data.records || []).forEach(r => addCommentCard(r, false));
        }
      } catch (e) {}
      setTimeout(pollFeedback, 1000);
    }

    async function refreshTree() {
      const output = document.getElementById("treeOutput");
      output.textContent = "Loading...";
      try {
        const res = await fetch(`/s/${token}/tree`);
        const json = await res.json();
        if (json.ok === false) {
          output.textContent = json.error ? json.error.message : "Driver unavailable";
          return;
        }
        output.textContent = JSON.stringify(json, null, 2);
      } catch (e) {
        output.textContent = "Failed to fetch tree: " + e;
      }
    }

    function showTab(tab) {
      document.getElementById("tabMainBtn").classList.toggle("active", tab === "main");
      document.getElementById("tabTreeBtn").classList.toggle("active", tab === "tree");
      if (tab === "tree") {
        document.getElementById("feedbackTab").style.display = "none";
        document.getElementById("controlBox").style.display = "none";
        document.getElementById("treeTab").style.display = "flex";
        refreshTree();
      } else {
        document.getElementById("treeTab").style.display = "none";
        if (currentMode === "control") {
          document.getElementById("controlBox").style.display = "flex";
          document.getElementById("feedbackTab").style.display = "none";
        } else {
          document.getElementById("feedbackTab").style.display = "flex";
          document.getElementById("controlBox").style.display = "none";
      }
    }

    async function copyToClipboard(text) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        return await navigator.clipboard.writeText(text);
      }
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.left = "-9999px";
      ta.style.top = "-9999px";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
    }

    async function copyPrompt(target, btn) {
      const originalText = btn.textContent;
      const url = typeof target === "number"
        ? `/s/${token}/feedback/prompt?seq=${target}`
        : `/s/${token}/feedback/prompt?scope=${target}`;
      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error("Failed to fetch prompt");
        const text = await res.text();
        await copyToClipboard(text);
        btn.textContent = "Copied!";
        btn.classList.add("copied");
        setTimeout(() => {
          btn.textContent = originalText;
          btn.classList.remove("copied");
        }, 1500);
      } catch (err) {
        showStatus("Copy failed: " + err, true);
      }
    }

    pollFeedback();
  </script>
</body>
</html>
"""#
    }
}
