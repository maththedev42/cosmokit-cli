import Foundation

struct ChatMessageWire: Codable {
    let id: UUID
    let threadId: UUID
    let from: String
    let text: String
    let at: Date
    let context: [String: String]?
    let feedbackSeq: Int?
}

struct ChatThreadWire: Codable {
    let id: UUID
    let agentName: String
    let clientName: String
    let workingDir: String?
    let createdAt: Date
    let lastSeenAt: Date
    let isOnline: Bool
    let unreadCount: Int
}

final class ChatClient {
    private let lock = NSLock()
    private var threadID: UUID?
    private var clientName = "mcp-client"
    private let workingDir = FileManager.default.currentDirectoryPath
    private var pollTask: DispatchWorkItem?
    private var onHumanMessage: (([ChatMessageWire]) -> Void)?
    private var mirroredSequences = Set<Int>()

    func setClientName(_ name: String) {
        lock.lock()
        clientName = name.isEmpty ? "mcp-client" : name
        lock.unlock()
    }

    func registerIfNeeded() throws {
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

    func start(channel: Bool, onHumanMessage: @escaping ([ChatMessageWire]) -> Void) {
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

    func stop() { pollTask?.cancel() }

    func heartbeat() throws -> Data {
        try registerIfNeeded()
        return try AppControl.request(path: "/v1/chat/agents/\(requiredThreadID())/heartbeat", method: "POST")
    }

    func read(wait: Double) throws -> [ChatMessageWire] {
        try registerIfNeeded()
        let bounded = min(max(wait, 0), 300)
        let path = "/v1/chat/threads/\(try requiredThreadID())/messages?unread=1&wait=\(String(format: "%.3f", bounded))"
        let data = try AppControl.request(path: path, timeout: max(5, bounded + 5))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ChatMessageWire].self, from: data)
    }

    func reply(_ text: String) throws -> ChatMessageWire {
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
