import Foundation
import CryptoKit

public struct UITreeFrame: Codable, Equatable {
    public let x: Double; public let y: Double; public let width: Double; public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

public struct UIElement: Codable, Equatable {
    public let ref: Int
    public let type: String
    public let identifier: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let frame: UITreeFrame?
    public let enabled: Bool?
    public let selected: Bool?
    public let focused: Bool?
    public let children: [UIElement]
    public init(ref: Int, type: String, identifier: String? = nil, label: String? = nil, value: String? = nil, placeholder: String? = nil, frame: UITreeFrame? = nil, enabled: Bool? = nil, selected: Bool? = nil, focused: Bool? = nil, children: [UIElement] = []) {
        self.ref = ref; self.type = type; self.identifier = identifier; self.label = label; self.value = value; self.placeholder = placeholder; self.frame = frame; self.enabled = enabled; self.selected = selected; self.focused = focused; self.children = children
    }
}

public struct UISnapshot: Codable, Equatable {
    public var screen: String?
    public let app: String?
    public let elements: [UIElement]
    public let truncated: Bool?
    public init(app: String? = nil, elements: [UIElement], truncated: Bool? = nil, screen: String? = nil) {
        self.app = app
        self.elements = elements
        self.truncated = truncated
        self.screen = screen
    }
}

public enum UITreeMode: String { case nav, act, debug }

public enum UITree {
    public static func parse(_ data: Data) throws -> UISnapshot { try JSONDecoder().decode(UISnapshot.self, from: data) }
    public static func parse(_ string: String) throws -> UISnapshot { try parse(Data(string.utf8)) }

    public static func actElements(in snapshot: UISnapshot) -> [UIElement] {
        var rows: [UIElement] = []
        func visit(_ element: UIElement) {
            if isInteractive(element) { rows.append(element) }
            element.children.forEach(visit)
        }
        snapshot.elements.forEach(visit)
        return rows
    }

    public static func screenHash(_ snapshot: UISnapshot) -> String {
        let rows = actElements(in: snapshot)
        let serialized = rows.map { e in
            let frameStr = e.frame.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? ""
            return "\(e.type)|\(e.label ?? "")|\(e.identifier ?? "")|\(frameStr)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(serialized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    public static func compact(_ snapshot: UISnapshot, mode: UITreeMode = .act, maxLines: Int = 80, includeScreen: Bool = true) -> String {
        let hash = snapshot.screen ?? screenHash(snapshot)
        var rows: [(UIElement, Int)] = []
        func visit(_ element: UIElement, level: Int) {
            let interactive = isInteractive(element)
            if mode == .debug || mode == .nav || interactive { rows.append((element, mode == .debug ? level : 0)) }
            if mode == .debug { element.children.forEach { visit($0, level: level + 1) } }
            else if mode == .nav { element.children.forEach { child in if interactive || isHeading(child) { visit(child, level: level + 1) } } }
            else { element.children.forEach { visit($0, level: level + 1) } }
        }
        snapshot.elements.forEach { visit($0, level: 0) }
        let limited = Array(rows.prefix(max(0, maxLines)))
        var output = limited.map { format($0.0, indent: mode == .debug ? String(repeating: "  ", count: $0.1) : "", mode: mode) }
        if rows.count > limited.count { output.append("… \(rows.count - limited.count) more (use --max \(maxLines))") }
        let body = output.joined(separator: "\n")
        if includeScreen {
            return "screen: \(hash)" + (body.isEmpty ? "" : "\n" + body)
        }
        return body
    }

    public static func find(_ snapshot: UISnapshot, text: String) -> [UIElement] {
        let needle = text.lowercased(); var result: [UIElement] = []
        func visit(_ e: UIElement) { if [e.label, e.value, e.identifier].compactMap({ $0 }).contains(where: { $0.lowercased().contains(needle) }) { result.append(e) }; e.children.forEach(visit) }
        snapshot.elements.forEach(visit); return result
    }

    public static func formatElement(_ e: UIElement, mode: UITreeMode = .act) -> String {
        format(e, indent: "", mode: mode)
    }

    private static let interactiveTypes: Set<String> = ["button", "textfield", "securetextfield", "switch", "slider", "cell", "link", "tab", "tabbar", "segmentedcontrol", "picker", "pickerwheel", "stepper", "toggle", "searchfield", "image"]
    public static func isInteractive(_ e: UIElement) -> Bool { interactiveTypes.contains(e.type.lowercased()) }
    private static func isHeading(_ e: UIElement) -> Bool { ["statictext", "heading", "navigationbar", "toolbar"].contains(e.type.lowercased()) }
    private static func quoted(_ value: String?) -> String { value.map { " \"\($0)\"" } ?? "" }
    private static func format(_ e: UIElement, indent: String, mode: UITreeMode) -> String {
        var line = "\(indent)[\(e.ref)] \(e.type)\(quoted(e.label ?? e.value))"
        if let f = e.frame { line += " (\(Int(f.x.rounded())),\(Int(f.y.rounded())) \(Int(f.width.rounded()))×\(Int(f.height.rounded())))" }
        if let value = e.value, e.label != nil { line += " value=\"\(value)\"" }
        if let placeholder = e.placeholder { line += " placeholder=\"\(placeholder)\"" }
        if mode == .debug, let id = e.identifier { line += " id=\"\(id)\"" }
        if e.enabled == false { line += " disabled" }; if e.selected == true { line += " selected" }; if e.focused == true { line += " focused" }
        return line
    }
}
