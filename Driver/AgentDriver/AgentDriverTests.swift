import Foundation
import Network
import XCTest

final class AgentDriverTests: XCTestCase {
    private var listener: NWListener?
    private let hostApp = XCUIApplication(bundleIdentifier: "apps.mjkweber.CosmoKitAgentHost")
    var currentTargetBundleID: String?
    private var refs: [Int: XCUIElement] = [:]
    private var nextRef = 1

    func testServe() {
        continueAfterFailure = true
        hostApp.launch()
        let rawPort = ProcessInfo.processInfo.environment["TEST_RUNNER_COSMOKIT_DRIVER_PORT"] ?? ProcessInfo.processInfo.environment["COSMOKIT_DRIVER_PORT"] ?? "8877"
        let port = NWEndpoint.Port(rawValue: UInt16(rawPort) ?? 8877)!
        listener = try? NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        listener?.start(queue: .main)
        RunLoop.main.run()
    }


    private func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_000_000) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = request.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            let method = first.first.map(String.init) ?? "GET"
            let rawPath = first.dropFirst().first.map(String.init) ?? "/"

            var queryParams: [String: String] = [:]
            let path: String
            if let questionIdx = rawPath.firstIndex(of: "?") {
                path = String(rawPath[..<questionIdx])
                let queryStr = String(rawPath[rawPath.index(after: questionIdx)...])
                for item in queryStr.components(separatedBy: "&") {
                    let pair = item.components(separatedBy: "=")
                    if let key = pair.first, !key.isEmpty {
                        let val = pair.count > 1 ? (pair[1].removingPercentEncoding ?? pair[1]) : ""
                        queryParams[key] = val
                    }
                }
            } else {
                path = rawPath
            }

            var bodyJSON: [String: Any] = [:]
            if let range = request.range(of: "\r\n\r\n") {
                let bodyString = String(request[range.upperBound...])
                if let bodyData = bodyString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    bodyJSON = json
                }
            }

            let response = self.handle(method: method, path: path, query: queryParams, body: bodyJSON)
            let bytes = Data(response.utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + bytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func handle(method: String, path: String, query: [String: String] = [:], body: [String: Any] = [:]) -> String {
        if path == "/quit" {
            DispatchQueue.main.async {
                self.listener?.cancel()
                CFRunLoopStop(CFRunLoopGetMain())
            }
            return "{\"ok\":true}"
        }
        if path == "/status" {
            let app = currentTargetBundleID ?? ""
            return encoded(["ok": true, "driverVersion": "0.2.0", "udid": "", "app": app])
        }
        if path == "/app" {
            if let newTarget = body["bundleId"] as? String ?? body["bundle_id"] as? String ?? body["app"] as? String ?? query["app"] ?? query["bundleId"] ?? query["bundle_id"], !newTarget.isEmpty {
                currentTargetBundleID = newTarget
                let target = XCUIApplication(bundleIdentifier: newTarget)
                if target.state == .notRunning {
                    target.launch()
                } else {
                    target.activate()
                }
                return encoded(["ok": true, "app": newTarget])
            }
            return encoded(["ok": true, "app": currentTargetBundleID ?? ""])
        }
        if path == "/tree" {
            let (targetApp, bundleID) = resolveTargetApp(query: query, body: body)
            return tree(for: targetApp, bundleID: bundleID)
        }
        if path == "/screenshot" {
            let (targetApp, _) = resolveTargetApp(query: query, body: body)
            let screenshot = targetApp.screenshot()
            let pngData = screenshot.pngRepresentation
            let base64 = pngData.base64EncodedString()
            return encoded(["ok": true, "image": base64])
        }
        if path == "/tap" {
            let (targetApp, _) = resolveTargetApp(query: query, body: body)
            if let ref = body["ref"] as? Int, let element = refs[ref] {
                element.tap()
                return "{\"ok\":true}"
            } else if let x = body["x"] as? Double, let y = body["y"] as? Double {
                let coord = targetApp.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
                coord.tap()
                return "{\"ok\":true}"
            }
            return "{\"ok\":true}"
        }
        if path == "/press" {
            if let ref = body["ref"] as? Int, let element = refs[ref] {
                let duration = (body["seconds"] as? Double) ?? 1.0
                element.press(forDuration: duration)
            }
            return "{\"ok\":true}"
        }
        if path == "/swipe" {
            let (targetApp, _) = resolveTargetApp(query: query, body: body)
            let direction = (body["direction"] as? String) ?? (body["action"] as? String) ?? "up"
            let targetElement: XCUIElement
            if let ref = body["ref"] as? Int, let elem = refs[ref] {
                targetElement = elem
            } else {
                targetElement = targetApp
            }
            switch direction.lowercased() {
            case "up": targetElement.swipeUp()
            case "down": targetElement.swipeDown()
            case "left": targetElement.swipeLeft()
            case "right": targetElement.swipeRight()
            default: targetElement.swipeUp()
            }
            return "{\"ok\":true}"
        }
        if path == "/type" {
            if let text = body["text"] as? String {
                if let ref = body["ref"] as? Int, let element = refs[ref] {
                    element.tap()
                    element.typeText(text)
                } else {
                    let (targetApp, _) = resolveTargetApp(query: query, body: body)
                    targetApp.typeText(text)
                }
            }
            return "{\"ok\":true}"
        }
        if path == "/button" {
            let name = (body["name"] as? String) ?? (body["action"] as? String) ?? ""
            switch name.lowercased() {
            case "home": XCUIDevice.shared.press(.home)
            default: break
            }
            return "{\"ok\":true}"
        }
        if path == "/alert" {
            let (targetApp, _) = resolveTargetApp(query: query, body: body)
            let action = (body["action"] as? String) ?? ""
            let alert = targetApp.alerts.firstMatch
            if alert.exists {
                if alert.buttons[action].exists {
                    alert.buttons[action].tap()
                } else if alert.buttons.count > 0 {
                    alert.buttons.firstMatch.tap()
                }
            }
            return "{\"ok\":true}"
        }
        return "{\"ok\":false,\"error\":{\"code\":\"unsupported\",\"message\":\"unknown endpoint\"}}"
    }

    private func resolveTargetApp(query: [String: String], body: [String: Any]) -> (XCUIApplication, String) {
        if let explicit = query["app"] ?? query["bundleId"] ?? query["bundle_id"] ?? body["app"] as? String ?? body["bundleId"] as? String ?? body["bundle_id"] as? String, !explicit.isEmpty {
            return (XCUIApplication(bundleIdentifier: explicit), explicit)
        }
        if let current = currentTargetBundleID, !current.isEmpty {
            return (XCUIApplication(bundleIdentifier: current), current)
        }
        return (hostApp, "apps.mjkweber.CosmoKitAgentHost")
    }

    private func tree(for app: XCUIApplication, bundleID: String) -> String {
        nextRef = 1
        refs.removeAll()
        let window = app.windows.firstMatch
        let elements = [window] + app.descendants(matching: .any).allElementsBoundByIndex
        let values: [[String: Any]] = elements.compactMap { element in
            guard element.exists else { return nil }
            let ref = nextRef
            nextRef += 1
            refs[ref] = element
            let frame = element.frame
            let x = frame.origin.x.isFinite ? Double(frame.origin.x) : 0.0
            let y = frame.origin.y.isFinite ? Double(frame.origin.y) : 0.0
            let w = frame.size.width.isFinite ? Double(frame.size.width) : 0.0
            let h = frame.size.height.isFinite ? Double(frame.size.height) : 0.0
            return [
                "ref": ref,
                "type": typeName(element.elementType),
                "id": element.identifier,
                "label": element.label,
                "value": element.value ?? "",
                "placeholder": "",
                "enabled": element.isEnabled,
                "selected": element.isSelected,
                "focused": element.isHittable,
                "frame": [
                    "x": x,
                    "y": y,
                    "width": w,
                    "height": h
                ],
                "children": []
            ]
        }
        return encoded(["app": bundleID, "elements": values, "truncated": false])
    }

    private func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "application"; case .group: return "group"; case .window: return "window"; case .button: return "button"; case .staticText: return "staticText"; case .textField: return "textField"; case .secureTextField: return "secureTextField"; case .cell: return "cell"; case .image: return "image"; case .navigationBar: return "navigationBar"; case .tabBar: return "tabBar"; case .tab: return "tab"; case .switch: return "switch"; case .slider: return "slider"; case .scrollView: return "scrollView"; case .table: return "table"; case .collectionView: return "collectionView"; default: return "element"
        }
    }

    private func encoded(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
