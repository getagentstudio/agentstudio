import AgentStudioPrimitives
import AgentStudioProgrammaticControl
import Foundation
import Testing

@Suite("CLI store read-through wire")
struct IPCCLIStoreReadThroughWireTests {
    @Test("authenticated encoding requires the read-through key even when its value is null")
    func authenticatedStatusEncodesExplicitNull() throws {
        let status = IPCAuthStatusResult.authenticated(
            principalId: UUIDv7.generate(), runtimeId: UUIDv7.generate(), accessMode: .agentStudioOnly)
        let data = try JSONEncoder().encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSObject])
        #expect(Set(object.keys) == ["authenticated", "principalId", "runtimeId", "accessMode", "cliStoreReadThrough"])
        #expect(object["cliStoreReadThrough"] is NSNull)
        #expect(try JSONDecoder().decode(IPCAuthStatusResult.self, from: data) == status)
        _ = try IPCAuthStatusResult.ipcSchema().normalize(data)
    }

    @Test("store-bound marks round trip with optional lifecycle prefix", arguments: [false, true])
    func authenticatedMarkRoundTrips(withLifecycle: Bool) throws {
        let mark = IPCCLIStoreReadThrough(
            storeId: UUIDv7.generate(), outbox: 42, lifecycleReport: withLifecycle ? 17 : nil)
        let status = IPCAuthStatusResult.authenticated(
            principalId: UUIDv7.generate(), runtimeId: UUIDv7.generate(), accessMode: .agentStudioOnly,
            cliStoreReadThrough: mark)
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(IPCAuthStatusResult.self, from: data) == status)
        _ = try IPCAuthStatusResult.ipcSchema().normalize(data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: NSObject])
        let storedMark = try #require(object["cliStoreReadThrough"] as? [String: NSObject])
        let expectedKeys: Set<String> =
            withLifecycle ? ["storeId", "outbox", "lifecycleReport"] : ["storeId", "outbox"]
        #expect(Set(storedMark.keys) == expectedKeys)
        #expect(storedMark["storeId"] as? String == mark.storeId.uuidString)
        #expect((storedMark["outbox"] as? NSNumber)?.int64Value == mark.outbox)
    }

    @Test("a missing required read-through field is rejected by decoding and the schema")
    func missingReadThroughIsRejected() throws {
        let data = try statusData(mark: nil)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(IPCAuthStatusResult.self, from: data) }
        #expect(throws: IPCSchemaValidationError.self) { try IPCAuthStatusResult.ipcSchema().normalize(data) }
    }

    @Test("read-through objects are closed even when decoded without a schema")
    func unknownKeysAreRejected() throws {
        let mark = IPCCLIStoreReadThrough(storeId: UUIDv7.generate(), outbox: 2)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(mark)) as? [String: NSObject])
        object["futureField"] = NSNumber(value: 1)
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(IPCCLIStoreReadThrough.self, from: data) }
        #expect(throws: IPCSchemaValidationError.self) { try IPCCLIStoreReadThrough.ipcSchema().normalize(data) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IPCAuthStatusResult.self, from: statusData(mark: object))
        }
    }

    @Test(
        "read-through counters encode only exact nonnegative JSON integers",
        arguments: [Int64(-1), IPCSchemaScalars.maximumExactInteger + 1, Int64.max])
    func unsafeCountersCannotBeEncoded(counter: Int64) throws {
        for mark in [
            IPCCLIStoreReadThrough(storeId: UUIDv7.generate(), outbox: counter),
            IPCCLIStoreReadThrough(storeId: UUIDv7.generate(), outbox: 0, lifecycleReport: counter),
        ] {
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(mark) }
            let status = IPCAuthStatusResult.authenticated(
                principalId: UUIDv7.generate(), runtimeId: UUIDv7.generate(), accessMode: .agentStudioOnly,
                cliStoreReadThrough: mark)
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(status) }
        }
    }

    @Test(
        "raw counters outside the safe-integer range are refused",
        arguments: ["-1", "9007199254740992", "9223372036854775807", "0.5"])
    func unsafeCountersCannotBeDecoded(counter: String) throws {
        let storeId = UUIDv7.generate()
        for field in ["outbox", "lifecycleReport"] {
            let payload =
                field == "outbox"
                ? "{\"storeId\":\"\(storeId)\",\"outbox\":\(counter)}"
                : "{\"storeId\":\"\(storeId)\",\"outbox\":0,\"lifecycleReport\":\(counter)}"
            let data = Data(payload.utf8)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(IPCCLIStoreReadThrough.self, from: data) }
            #expect(throws: IPCSchemaValidationError.self) { try IPCCLIStoreReadThrough.ipcSchema().normalize(data) }
        }
    }

    @Test(
        "zero and the largest exact integer retain their values",
        arguments: [Int64(0), IPCSchemaScalars.maximumExactInteger])
    func exactBoundaryCountersRoundTrip(counter: Int64) throws {
        let mark = IPCCLIStoreReadThrough(storeId: UUIDv7.generate(), outbox: counter, lifecycleReport: counter)
        let data = try JSONEncoder().encode(mark)
        #expect(try JSONDecoder().decode(IPCCLIStoreReadThrough.self, from: data) == mark)
        _ = try IPCCLIStoreReadThrough.ipcSchema().normalize(data)
    }

    @Test("unauthenticated status never carries a store mark")
    func unauthenticatedStatusRejectsReadThrough() throws {
        let data = Data(#"{"authenticated":false,"cliStoreReadThrough":null}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(IPCAuthStatusResult.self, from: data) }
        #expect(throws: IPCSchemaValidationError.self) { try IPCAuthStatusResult.ipcSchema().normalize(data) }
    }

    private func statusData(mark: [String: NSObject]?) throws -> Data {
        var object: [String: NSObject] = [
            "authenticated": NSNumber(value: true), "principalId": UUIDv7.generate().uuidString as NSString,
            "runtimeId": UUIDv7.generate().uuidString as NSString, "accessMode": "agentStudioOnly" as NSString,
        ]
        if let mark { object["cliStoreReadThrough"] = mark as NSDictionary }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
