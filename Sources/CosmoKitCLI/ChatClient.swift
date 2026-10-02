import Foundation

public struct ChatMessageWire: Codable {
    public let id: UUID
    public let threadId: UUID
    public let from: String
    public let text: String
    public let at: Date
    public let context: [String: String]?
    public let feedbackSeq: Int?

    enum CodingKeys: String, CodingKey {
        case id, threadId, from, text, at, context, feedbackSeq
    }

    public init(id: UUID, threadId: UUID, from: String, text: String, at: Date, context: [String: String]? = nil, feedbackSeq: Int? = nil) {
        self.id = id
        self.threadId = threadId
        self.from = from
        self.text = text
        self.at = at
        self.context = context
        self.feedbackSeq = feedbackSeq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        threadId = try container.decode(UUID.self, forKey: .threadId)
        from = try container.decode(String.self, forKey: .from)
        text = try container.decode(String.self, forKey: .text)
        context = try container.decodeIfPresent([String: String].self, forKey: .context)
        feedbackSeq = try container.decodeIfPresent(Int.self, forKey: .feedbackSeq)

        if let date = try? container.decode(Date.self, forKey: .at) {
            at = date
        } else if let num = try? container.decode(Double.self, forKey: .at) {
            at = num > 1_000_000_000 ? Date(timeIntervalSince1970: num) : Date(timeIntervalSinceReferenceDate: num)
        } else if let str = try? container.decode(String.self, forKey: .at) {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: str) ?? ISO8601DateFormatter().date(from: str) {
                at = date
            } else if let num = Double(str) {
                at = num > 1_000_000_000 ? Date(timeIntervalSince1970: num) : Date(timeIntervalSinceReferenceDate: num)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "Invalid date format: \(str)")
            }
        } else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "Expected Date, Double, or String for 'at'")
        }
    }
}

public struct ChatThreadWire: Codable {
    public let id: UUID
    public let agentName: String
    public let clientName: String
    public let workingDir: String?
    public let createdAt: Date
    public let lastSeenAt: Date
    public let isOnline: Bool
    public let unreadCount: Int
}

public final class ChatClient {
    private let lock = NSLock()
    private var threadID: UUID?
    private var clientName = "mcp-client"
    private let workingDir: String
    private var pollTask: DispatchWorkItem?
    private var onHumanMessage: (([ChatMessageWire]) -> Void)?
    private var mirroredSequences = Set<Int>()

    public init(clientName: String = "mcp-client", workingDir: String = FileManager.default.currentDirectoryPath) {
        self.clientName = clientName
        self.workingDir = workingDir
    }

    public var currentThreadID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return threadID
    }

    public func setClientName(_ name: String) {
        lock.lock()
        clientName = name.isEmpty ? "mcp-client" : name
        lock.unlock()
    }

    public func registerIfNeeded() throws {
        lock.lock()
        if threadID != nil { lock.unlock(); return }
        let name = clientName
        lock.unlock()
        let body = try JSONSerialization.data(withJSONObject: ["clientName": name, "workingDir": workingDir])
        let data = try AppControl.request(path: "/v1/chat/agents", method: "POST", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawID = object["threadId"] as? String, let id = UUID(uuidString: rawID) else {
            throw CLIError(commandError: CommandError(code: .driverUnavailable, message: "CosmoKit returned an invalid chat thread"))
        }
        lock.lock()
        threadID = id
        lock.unlock()
    }

    public func start(channel: Bool, onHumanMessage: @escaping ([ChatMessageWire]) -> Void) {
        pollTask?.cancel()
        self.onHumanMessage = onHumanMessage
        var task: DispatchWorkItem!
        task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            while !task.isCancelled {
                do {
                    try self.registerIfNeeded()
                    _ = try self.heartbeat()
                    if channel {
                        let messages = try self.read(wait: 20)
                        if !messages.isEmpty { onHumanMessage(messages) }
                    } else {
                        Thread.sleep(forTimeInterval: 20)
                    }
                } catch {
                    self.clearThread()
                    Thread.sleep(forTimeInterval: 20)
                }
            }
        }
        pollTask = task
        DispatchQueue.global(qos: .utility).async(execute: task)
    }

    public func stop() { pollTask?.cancel() }

    public func heartbeat() throws -> Data {
        try registerIfNeeded()
        return try AppControl.request(path: "/v1/chat/agents/\(requiredThreadID())/heartbeat", method: "POST")
    }

    public func read(wait: Double) throws -> [ChatMessageWire] {
        try registerIfNeeded()
        let bounded = min(max(wait, 0), 300)
        let path = "/v1/chat/threads/\(try requiredThreadID())/messages?unread=1&wait=\(String(format: "%.3f", bounded))"
        let data: Data
        do {
            data = try AppControl.request(path: path, timeout: bounded + 20)
        } catch let error as CLIError {
            throw error
        } catch let urlError as URLError where urlError.code == .timedOut {
            return []
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                return []
            }
            throw error
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ChatMessageWire].self, from: data)
    }

    public func reply(_ text: String) throws -> ChatMessageWire {
        guard text.count <= 20_000 else {
            throw CLIError(commandError: CommandError(code: .usage, message: "text must be at most 20,000 characters"))
        }
        try registerIfNeeded()
        let body = try JSONSerialization.data(withJSONObject: ["from": "agent", "text": text])
        let data = try AppControl.request(path: "/v1/chat/threads/\(requiredThreadID())/messages", method: "POST", body: body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatMessageWire.self, from: data)
    }

    func status() throws -> [String: Any] {
        try registerIfNeeded()
        let data = try AppControl.request(path: "/v1/chat/threads")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let threads = try decoder.decode([ChatThreadWire].self, from: data)
        let id = try requiredThreadID()
        let thread = threads.first { $0.id == id }
        let version = (try? AppControl.readControlInfo().version) ?? "unknown"
        return [
            "threadId": id.uuidString,
            "online": thread?.isOnline ?? false,
            "unread": thread?.unreadCount ?? 0,
            "appVersion": version
        ]
    }

    func mirror(_ record: FeedbackRecordPayload) {
        guard let id = try? requiredThreadID() else { return }
        lock.lock()
        if mirroredSequences.contains(record.seq) { lock.unlock(); return }
        mirroredSequences.insert(record.seq)
        lock.unlock()
        let object: [String: Any] = [
            "seq": record.seq,
            "text": record.text,
            "element": record.element.label ?? record.element.identifier ?? record.element.type,
            "x": record.x,
            "y": record.y
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
        if (try? AppControl.request(path: "/v1/chat/threads/\(id)/feedback-mirror", method: "POST", body: body)) == nil {
            lock.lock()
            mirroredSequences.remove(record.seq)
            lock.unlock()
        }
    }

    private func requiredThreadID() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard let threadID else {
            throw CLIError(commandError: CommandError(code: .appNotRunning, message: "CosmoKit chat is unavailable", hint: "Open CosmoKit"))
        }
        return threadID
    }

    private func clearThread() {
        lock.lock()
        threadID = nil
        lock.unlock()
    }
}

extension ChatMessageWire {
    var compactText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var result = "[human \(formatter.string(from: at))] \(text)"
        if let context, !context.isEmpty {
            var values: [String] = []
            if let udid = context["udid"] { values.append("udid=\(udid)") }
            if let bundleID = context["bundleId"] { values.append("app=\(bundleID)") }
            if let screenshot = context["screenshotPath"] { values.append("screenshot=\(screenshot)") }
            if !values.isEmpty { result += "\ncontext: \(values.joined(separator: " "))" }
        }
        return result
    }
}
