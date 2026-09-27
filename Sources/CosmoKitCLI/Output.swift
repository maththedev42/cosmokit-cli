//
//  Output.swift
//  cosmokit CLI
//
//  Stable machine-readable output shared by the CLI and its agent-facing
//  transports.
//

import Foundation

/// Stable machine identifiers for failures. An agent branches on `code`;
/// `message` is for a human reading a transcript and may be reworded freely.
public enum ErrorCode: String, Codable {
    case usage
    case deviceNotFound
    case noSimulator
    case simctlFailed
    case unknownCommand
    case driverUnavailable
    case refStale
    case refNotFound
    case unsupported
    case timeout
    case screenChanged
    case appNotRunning
    case appTooOld
    case proxyNotRunning
}

public struct FeedbackElementPayload: Codable, Equatable {
    public let ref: Int
    public let type: String
    public let label: String?
    public let identifier: String?
    public let frame: UITreeFrame?
    public init(ref: Int, type: String, label: String? = nil, identifier: String? = nil, frame: UITreeFrame? = nil) {
        self.ref = ref; self.type = type; self.label = label; self.identifier = identifier; self.frame = frame
    }
}

public struct FeedbackRecordPayload: Codable, Equatable {
    public let seq: Int
    public let at: String
    public let x: Double
    public let y: Double
    public let element: FeedbackElementPayload
    public let text: String
    public let frame: String
    public let branch: String?
    public let worktree: String?
    public let app: String?
    public let udid: String
    public var acked: Bool?
    public init(seq: Int, at: String, x: Double, y: Double, element: FeedbackElementPayload, text: String, frame: String, branch: String? = nil, worktree: String? = nil, app: String? = nil, udid: String, acked: Bool? = false) {
        self.seq = seq; self.at = at; self.x = x; self.y = y; self.element = element; self.text = text; self.frame = frame; self.branch = branch; self.worktree = worktree; self.app = app; self.udid = udid; self.acked = acked
    }
}

public struct StreamStatusPayload: Codable, Equatable {
    public let running: Bool
    public let port: Int?
    public let pid: Int?
    public let url: String?
    public init(running: Bool, port: Int? = nil, pid: Int? = nil, url: String? = nil) {
        self.running = running; self.port = port; self.pid = pid; self.url = url
    }
}

public struct FeedbackListPayload: Codable, Equatable {
    public let records: [FeedbackRecordPayload]
    public init(records: [FeedbackRecordPayload]) { self.records = records }
}

public struct FeedbackClearPayload: Codable, Equatable {
    public let cleared: Bool
    public let count: Int
    public init(cleared: Bool, count: Int) { self.cleared = cleared; self.count = count }
}

public struct FeedbackPromptPayload: Codable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct DriverStatusPayload: Codable {
    public let running: Bool
    public let port: Int?
    public let pid: Int?
    public let app: String?
    public init(running: Bool, port: Int? = nil, pid: Int? = nil, app: String? = nil) {
        self.running = running; self.port = port; self.pid = pid; self.app = app
    }
}

public struct DriverActionPayload: Codable {
    public let ok: Bool
    public let message: String
    public init(ok: Bool = true, message: String) { self.ok = ok; self.message = message }
}

public struct UIScreenshotPayload: Codable {
    public let path: String
    public let width: Int
    public let height: Int
    public let bytes: Int
    public init(path: String, width: Int, height: Int, bytes: Int) { self.path = path; self.width = width; self.height = height; self.bytes = bytes }
}

public struct CommandError: Codable, Equatable {
    public let code: ErrorCode
    public let message: String
    public let expected: String?
    public let actual: String?
    public let hint: String?

    public init(code: ErrorCode, message: String, expected: String? = nil, actual: String? = nil, hint: String? = nil) {
        self.code = code
        self.message = message
        self.expected = expected
        self.actual = actual
        self.hint = hint
    }
}

public struct NetworkProxyInfoPayload: Codable, Equatable {
    public let running: Bool
    public let port: Int
    public init(running: Bool, port: Int) {
        self.running = running
        self.port = port
    }
}

public struct NetworkConditionsPayload: Codable, Equatable {
    public let preset: String?
    public let latencyMs: Int?
    public let downloadKbps: Int?
    public let uploadKbps: Int?
    public let failureRatePercent: Int?
    public let failureMode: String?
    public let timeoutSeconds: Int?
    public init(
        preset: String? = nil,
        latencyMs: Int? = nil,
        downloadKbps: Int? = nil,
        uploadKbps: Int? = nil,
        failureRatePercent: Int? = nil,
        failureMode: String? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.preset = preset
        self.latencyMs = latencyMs
        self.downloadKbps = downloadKbps
        self.uploadKbps = uploadKbps
        self.failureRatePercent = failureRatePercent
        self.failureMode = failureMode
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct NetworkStatusPayload: Codable, Equatable {
    public let proxy: NetworkProxyInfoPayload
    public let conditions: NetworkConditionsPayload
    public let offline: Bool
    public init(proxy: NetworkProxyInfoPayload, conditions: NetworkConditionsPayload, offline: Bool) {
        self.proxy = proxy
        self.conditions = conditions
        self.offline = offline
    }
}

public struct WaitPayload: Codable, Equatable {
    public let screen: String
    public let ref: Int?
    public let element: FeedbackElementPayload?
    public let gone: Bool
    public init(screen: String, ref: Int? = nil, element: FeedbackElementPayload? = nil, gone: Bool = false) {
        self.screen = screen; self.ref = ref; self.element = element; self.gone = gone
    }
}

public struct DoPayload: Codable, Equatable {
    public let screen: String
    public let stepsCompleted: Int
    public let totalSteps: Int
    public let app: String?
    public init(screen: String, stepsCompleted: Int, totalSteps: Int, app: String? = nil) {
        self.screen = screen; self.stepsCompleted = stepsCompleted; self.totalSteps = totalSteps; self.app = app
    }
}

public struct DoFailurePayload: Codable, Equatable {
    public let failedStep: Int
    public let totalSteps: Int
    public let error: CommandError
    public init(failedStep: Int, totalSteps: Int, error: CommandError) {
        self.failedStep = failedStep; self.totalSteps = totalSteps; self.error = error
    }
}

public struct EmptyPayload: Encodable {
    public init() {}
}

public struct BootPayload: Codable {
    public let udid: String
    public let name: String
    public let alreadyBooted: Bool

    public init(udid: String, name: String, alreadyBooted: Bool) {
        self.udid = udid
        self.name = name
        self.alreadyBooted = alreadyBooted
    }
}

public struct ShutdownPayload: Codable {
    public let udid: String
    public let name: String

    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }
}

public struct CapturePayload: Codable {
    public let udid: String
    public let name: String
    public let path: String

    public init(udid: String, name: String, path: String) {
        self.udid = udid
        self.name = name
        self.path = path
    }
}

public struct RecordPayload: Codable {
    public let udid: String
    public let name: String
    public let path: String

    public init(udid: String, name: String, path: String) {
        self.udid = udid
        self.name = name
        self.path = path
    }
}

public struct LocationPayload: Codable {
    public let udid: String
    public let name: String
    public let latitude: Double
    public let longitude: Double

    public init(udid: String, name: String, latitude: Double, longitude: Double) {
        self.udid = udid
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct OpenPayload: Codable {
    public let udid: String
    public let name: String
    public let url: String

    public init(udid: String, name: String, url: String) {
        self.udid = udid
        self.name = name
        self.url = url
    }
}

public struct ErasePayload: Codable {
    public let udid: String
    public let name: String

    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }
}

public struct Envelope<Payload: Encodable>: Encodable {
    public let ok: Bool
    public let payload: Payload?
    public let error: CommandError?

    public init(ok: Bool, payload: Payload? = nil, error: CommandError? = nil) {
        self.ok = ok
        self.payload = payload
        self.error = error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeyImpl.self)
        try container.encode(ok, forKey: CodingKeyImpl(stringValue: "ok"))

        if let error {
            try container.encode(error, forKey: CodingKeyImpl(stringValue: "error"))
        } else if let payload {
            let payloadData = try JSONEncoder().encode(payload)
            let payloadObject = try JSONSerialization.jsonObject(with: payloadData)
            guard let payloadDictionary = payloadObject as? [String: Any] else {
                throw EncodingError.invalidValue(
                    payload,
                    EncodingError.Context(codingPath: [], debugDescription: "Envelope payload must encode as a JSON object")
                )
            }
            for (key, value) in payloadDictionary {
                try container.encode(JSONValue(value), forKey: CodingKeyImpl(stringValue: key))
            }
        }
    }
}

private struct CodingKeyImpl: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) { return nil }
}

private struct JSONValue: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try single.encodeNil()
        case let value as Bool:
            try single.encode(value)
        case let value as String:
            try single.encode(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            try single.encode(value.boolValue)
        case let value as NSNumber:
            try single.encode(value.doubleValue)
        case let value as [Any]:
            try single.encode(value.map(JSONValue.init))
        case let value as [String: Any]:
            try single.encode(value.mapValues(JSONValue.init))
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
}
