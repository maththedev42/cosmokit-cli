import Foundation

public enum FeedbackStore {
    public static var baseDirectoryOverride: URL?

    public static func feedbackDirectory(for udid: String) -> URL {
        if let base = baseDirectoryOverride {
            return base.appendingPathComponent(udid)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/cosmokit/feedback/\(udid)")
    }

    public static func jsonlFile(for udid: String) -> URL {
        feedbackDirectory(for: udid).appendingPathComponent("feedback.jsonl")
    }

    public static func readAll(udid: String) -> [FeedbackRecordPayload] {
        let file = jsonlFile(for: udid)
        guard let data = try? Data(contentsOf: file),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var records: [FeedbackRecordPayload] = []
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            if let record = try? decoder.decode(FeedbackRecordPayload.self, from: lineData) {
                records.append(record)
            }
        }
        return records
    }

    public static func append(udid: String,
                              x: Double,
                              y: Double,
                              element: FeedbackElementPayload,
                              text: String,
                              framePath: String,
                              branch: String?,
                              worktree: String?,
                              app: String?) throws -> FeedbackRecordPayload {
        let dir = feedbackDirectory(for: udid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = readAll(udid: udid)
        let nextSeq = (existing.map(\.seq).max() ?? 0) + 1
        let isoFormatter = ISO8601DateFormatter()
        let record = FeedbackRecordPayload(
            seq: nextSeq,
            at: isoFormatter.string(from: Date()),
            x: x,
            y: y,
            element: element,
            text: text,
            frame: framePath,
            branch: branch,
            worktree: worktree,
            app: app,
            udid: udid,
            acked: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let file = jsonlFile(for: udid)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data("\n".utf8))
            try? handle.close()
        } else {
            var content = data
            content.append(contentsOf: Data("\n".utf8))
            try content.write(to: file, options: .atomic)
        }
        return record
    }

    public static func ack(udid: String, seq: Int) throws -> FeedbackRecordPayload? {
        let records = readAll(udid: udid)
        guard let index = records.firstIndex(where: { $0.seq == seq }) else { return nil }
        var updated = records
        let item = updated[index]
        let newAcked = !(item.acked ?? false)
        let changed = FeedbackRecordPayload(
            seq: item.seq,
            at: item.at,
            x: item.x,
            y: item.y,
            element: item.element,
            text: item.text,
            frame: item.frame,
            branch: item.branch,
            worktree: item.worktree,
            app: item.app,
            udid: item.udid,
            acked: newAcked
        )
        updated[index] = changed

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        for rec in updated {
            let data = try encoder.encode(rec)
            output.append(data)
            output.append(Data("\n".utf8))
        }
        try output.write(to: jsonlFile(for: udid), options: .atomic)
        return changed
    }

    public static func clear(udid: String) throws -> Int {
        let records = readAll(udid: udid)
        let dir = feedbackDirectory(for: udid)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        return records.count
    }

    public static func nextUnread(udid: String, wait: TimeInterval = 0) -> FeedbackRecordPayload? {
        let start = Date()
        while true {
            let records = readAll(udid: udid)
            if let unacked = records.first(where: { ($0.acked ?? false) == false }) {
                return unacked
            }
            if wait <= 0 || Date().timeIntervalSince(start) >= wait {
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    public static func formatCompact(_ record: FeedbackRecordPayload) -> String {
        var line = "#\(record.seq) on [\(record.element.ref)] \(record.element.type)"
        if let label = record.element.label, !label.isEmpty {
            line += " \"\(label)\""
        }
        if let id = record.element.identifier, !id.isEmpty {
            line += " (id: \(id))"
        }
        line += " at (\(Int(record.x.rounded())),\(Int(record.y.rounded()))) — \"\(record.text)\""
        var meta: [String] = ["frame: \(record.frame)"]
        if let branch = record.branch, !branch.isEmpty {
            meta.append("branch: \(branch)")
        }
        line += " (\(meta.joined(separator: ", ")))"
        return line
    }

    public static let containerTypes: Set<String> = [
        "window", "other", "scrollview", "table", "collectionview",
        "group", "application", "splitgroup", "drawer", "popover",
        "sheet", "alert", "dialog", "layoutarea", "layoutitem"
    ]

    public static func resolveElement(in snapshot: UISnapshot, x: Double, y: Double) -> UIElement? {
        var matches: [(element: UIElement, depth: Int, area: Double, isContainer: Bool)] = []

        func walk(_ element: UIElement, depth: Int) {
            if let f = element.frame {
                let contains = (x >= f.x && x <= f.x + f.width && y >= f.y && y <= f.y + f.height)
                if contains {
                    let isContainer = containerTypes.contains(element.type.lowercased())
                    let area = f.width * f.height
                    matches.append((element, depth, area, isContainer))
                }
            }
            for child in element.children {
                walk(child, depth: depth + 1)
            }
        }

        for root in snapshot.elements {
            walk(root, depth: 0)
        }

        guard !matches.isEmpty else { return nil }

        let nonContainers = matches.filter { !$0.isContainer }
        let candidates = nonContainers.isEmpty ? matches : nonContainers

        // Pick deepest candidate; break ties by smallest area, then by ref
        let sorted = candidates.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            if abs($0.area - $1.area) > 0.01 { return $0.area < $1.area }
            return $0.element.ref > $1.element.ref
        }
        return sorted.first?.element
    }
}
