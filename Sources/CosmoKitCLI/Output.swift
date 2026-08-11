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
}

public struct CommandError: Codable {
    public let code: ErrorCode
    public let message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
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
