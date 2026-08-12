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

    func testAppPayloadsEncodeWithStableKeys() throws {
        XCTAssertEqual(try json(InstallPayload(udid: "U", name: "iPhone", path: "/tmp/My.app")), "{\"name\":\"iPhone\",\"path\":\"\\/tmp\\/My.app\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(UninstallPayload(udid: "U", name: "iPhone", bundleID: "com.example.app")), "{\"bundleID\":\"com.example.app\",\"name\":\"iPhone\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(LaunchPayload(udid: "U", name: "iPhone", bundleID: "com.example.app", pid: 123)), "{\"bundleID\":\"com.example.app\",\"name\":\"iPhone\",\"pid\":123,\"udid\":\"U\"}")
        XCTAssertEqual(try json(TerminatePayload(udid: "U", name: "iPhone", bundleID: "com.example.app")), "{\"bundleID\":\"com.example.app\",\"name\":\"iPhone\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(ContainerPayload(udid: "U", name: "iPhone", bundleID: "com.example.app", kind: "data", path: "/data/app")), "{\"bundleID\":\"com.example.app\",\"kind\":\"data\",\"name\":\"iPhone\",\"path\":\"\\/data\\/app\",\"udid\":\"U\"}")
    }

    func testLaunchPayloadWithNilPIDKeepsIdentity() throws {
        let data = try JSONEncoder().encode(LaunchPayload(udid: "U", name: "iPhone", bundleID: "com.example.app", pid: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["bundleID"] as? String, "com.example.app")
        XCTAssertEqual(object["udid"] as? String, "U")
        XCTAssertEqual(object["name"] as? String, "iPhone")
    }

    func testListAppsParsesOpenStepPlist() throws {
        let sample = #"""
        {
            "com.example.alpha" = {
                CFBundleIdentifier = "com.example.alpha";
                CFBundleDisplayName = "Alpha App";
                Bundle = "/Applications/Alpha.app";
                ApplicationType = User;
            };
            "com.apple.system" = {
                CFBundleIdentifier = "com.apple.system";
                CFBundleDisplayName = "System; Tools";
                Path = "/Applications/System.app";
                ApplicationType = System;
            };
            "com.example.fallback" = {
                CFBundleIdentifier = "com.example.fallback";
                CFBundleName = "Fallback";
            };
        }
        """#
        let apps = try CLI.parseInstalledApps(sample)
        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.system", "com.example.alpha", "com.example.fallback"])
        XCTAssertEqual(apps[0].name, "System; Tools")
        XCTAssertEqual(apps[0].type, "System")
        XCTAssertEqual(apps[1].path, "/Applications/Alpha.app")
        XCTAssertEqual(apps[2].name, "Fallback")
    }

    func testSimulatorStatePayloadsEncodeWithStableKeys() throws {
        XCTAssertEqual(try json(AppearancePayload(udid: "U", name: "iPhone", appearance: "dark")), "{\"appearance\":\"dark\",\"name\":\"iPhone\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(StatusBarPayload(udid: "U", name: "iPhone", overrides: ["time": "9:41"])), "{\"name\":\"iPhone\",\"overrides\":{\"time\":\"9:41\"},\"udid\":\"U\"}")
        XCTAssertEqual(try json(StatusBarClearPayload(udid: "U", name: "iPhone")), "{\"name\":\"iPhone\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(PermissionPayload(udid: "U", name: "iPhone", action: "grant", service: "photos", bundleID: "com.example.app")), "{\"action\":\"grant\",\"bundleID\":\"com.example.app\",\"name\":\"iPhone\",\"service\":\"photos\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(BiometricEnrollPayload(udid: "U", name: "iPhone", enrolled: true)), "{\"enrolled\":true,\"name\":\"iPhone\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(BiometricMatchPayload(udid: "U", name: "iPhone", result: "match")), "{\"name\":\"iPhone\",\"result\":\"match\",\"udid\":\"U\"}")
    }

    func testContentPayloadsEncodeWithStableKeys() throws {
        XCTAssertEqual(try json(PushPayload(udid: "U", name: "iPhone", bundleID: "com.example.app", payloadBytes: 42)), "{\"bundleID\":\"com.example.app\",\"name\":\"iPhone\",\"payloadBytes\":42,\"udid\":\"U\"}")
        XCTAssertEqual(try json(ScenariosPayload(udid: "U", name: "iPhone", scenarios: ["City Run"])), "{\"name\":\"iPhone\",\"scenarios\":[\"City Run\"],\"udid\":\"U\"}")
        XCTAssertEqual(try json(RoutePayload(udid: "U", name: "iPhone", scenario: "City Run")), "{\"name\":\"iPhone\",\"scenario\":\"City Run\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(LocationClearPayload(udid: "U", name: "iPhone")), "{\"name\":\"iPhone\",\"udid\":\"U\"}")
        XCTAssertEqual(try json(AddMediaPayload(udid: "U", name: "iPhone", paths: ["/tmp/a.jpg"], count: 1)), "{\"count\":1,\"name\":\"iPhone\",\"paths\":[\"\\/tmp\\/a.jpg\"],\"udid\":\"U\"}")
        XCTAssertEqual(try json(PasteboardPayload(udid: "U", name: "iPhone", contents: "hello", didSet: true)), "{\"contents\":\"hello\",\"didSet\":true,\"name\":\"iPhone\",\"udid\":\"U\"}")
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
