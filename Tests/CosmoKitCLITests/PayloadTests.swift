import XCTest
@testable import CosmoKitCLI

final class PayloadTests: XCTestCase {
    func testActionPayloadsEncodeWithStableKeys() throws {
        XCTAssertEqual(try json(BootPayload(udid: "UDID", name: "iPhone 16", alreadyBooted: false)), "{\"alreadyBooted\":false,\"name\":\"iPhone 16\",\"udid\":\"UDID\"}")
        XCTAssertEqual(try json(ShutdownPayload(udid: "UDID", name: "iPhone 16")), "{\"name\":\"iPhone 16\",\"udid\":\"UDID\"}")
        XCTAssertEqual(try json(CapturePayload(udid: "UDID", name: "iPhone 16", path: "/tmp/capture.png")), "{\"name\":\"iPhone 16\",\"path\":\"\\/tmp\\/capture.png\",\"udid\":\"UDID\"}")
        XCTAssertEqual(try json(RecordPayload(udid: "UDID", name: "iPhone 16", path: "/tmp/record.mp4")), "{\"name\":\"iPhone 16\",\"path\":\"\\/tmp\\/record.mp4\",\"udid\":\"UDID\"}")
        XCTAssertEqual(try json(LocationPayload(udid: "UDID", name: "iPhone 16", latitude: -22.9068, longitude: -43.1729)), "{\"latitude\":-22.9068,\"longitude\":-43.1729,\"name\":\"iPhone 16\",\"udid\":\"UDID\"}")
        XCTAssertEqual(try json(OpenPayload(udid: "UDID", name: "iPhone 16", url: "myapp://item/42")), "{\"name\":\"iPhone 16\",\"udid\":\"UDID\",\"url\":\"myapp:\\/\\/item\\/42\"}")
        XCTAssertEqual(try json(ErasePayload(udid: "UDID", name: "iPhone 16")), "{\"name\":\"iPhone 16\",\"udid\":\"UDID\"}")
    }

    func testBootPayloadKeepsAlreadyBootedTrue() throws {
        XCTAssertEqual(try json(BootPayload(udid: "UDID", name: "iPhone", alreadyBooted: true)), "{\"alreadyBooted\":true,\"name\":\"iPhone\",\"udid\":\"UDID\"}")
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
