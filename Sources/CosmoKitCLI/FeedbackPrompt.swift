import Foundation

public enum FeedbackPrompt {
    public static func render(_ records: [FeedbackRecordPayload], app: String? = nil) -> String {
        if records.isEmpty {
            return "No feedback to render."
        }

        let sorted = records.sorted { $0.seq < $1.seq }
        let blocks: [String] = sorted.map { record in
            let appName = (record.app?.isEmpty == false ? record.app : nil)
                ?? (app?.isEmpty == false ? app : nil)
                ?? "app"
            let udidShort = record.udid.isEmpty ? "—" : String(record.udid.prefix(8))
            let header = "## Feedback #\(record.seq) — \(appName) on \(udidShort)"

            let type = record.element.type.isEmpty ? "element" : record.element.type
            let rawLabel = record.element.label ?? ""
            let escapedLabel = rawLabel.replacingOccurrences(of: "`", with: "\\`")
            let idStr = (record.element.identifier?.isEmpty == false) ? record.element.identifier! : "—"
            let frameStr: String
            if let f = record.element.frame {
                frameStr = "frame \(Int(f.x.rounded())),\(Int(f.y.rounded())) \(Int(f.width.rounded()))×\(Int(f.height.rounded()))"
            } else {
                frameStr = "frame —"
            }
            let elementLine = "Element: \(type) \"\(escapedLabel)\" (id: \(idStr), ref \(record.element.ref), \(frameStr))"

            let pointLine = "Point: (\(Int(round(record.x))),\(Int(round(record.y)))) pt"

            let escapedText = record.text.replacingOccurrences(of: "`", with: "\\`")
            let noteLine = escapedText.isEmpty ? "Note:" : "Note: \(escapedText)"

            let screenshotPath: String
            if record.frame.hasPrefix("/") {
                screenshotPath = record.frame
            } else if !record.frame.isEmpty {
                screenshotPath = FeedbackStore.feedbackDirectory(for: record.udid).appendingPathComponent(record.frame).path
            } else {
                screenshotPath = FeedbackStore.feedbackDirectory(for: record.udid).appendingPathComponent("\(record.seq).png").path
            }
            let screenshotLine = "Screenshot: \(screenshotPath)"

            let branchStr = (record.branch?.isEmpty == false) ? record.branch! : "—"
            let worktreeStr = (record.worktree?.isEmpty == false) ? record.worktree! : "—"
            let branchLine = "Branch: \(branchStr)  Worktree: \(worktreeStr)"

            let lines = [header, elementLine, pointLine, noteLine, screenshotLine, branchLine]
            return lines.map { stripTrailingWhitespace($0) }.joined(separator: "\n")
        }

        let footerLines = [
            "To act on this: `cosmokit ui tree --mode act` then `cosmokit ui tap <ref> --screen <hash>`.",
            "Mark done with `cosmokit feedback ack <seq>`."
        ]
        let footer = footerLines.map { stripTrailingWhitespace($0) }.joined(separator: "\n")

        return (blocks + [footer]).joined(separator: "\n\n")
    }

    private static func stripTrailingWhitespace(_ line: String) -> String {
        var result = line
        while result.hasSuffix(" ") || result.hasSuffix("\t") {
            result.removeLast()
        }
        return result
    }
}
