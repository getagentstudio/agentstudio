import Darwin
import Foundation
import Testing

/// The SDK's public arm64 Testing.swiftinterface:736-750 exposes current and
/// isParameterized, but no case ID. Its module has no importable SPI interface.
/// Keep caseID null; a parameterized test's waits have partial case attribution.
package struct TestEventLogIdentity: Sendable {
    let testID: String
    let parameterized: Bool?

    static var current: Self? {
        guard let test = Test.current else { return nil }
        return Self(
            testID: String(describing: test.id),
            parameterized: Test.Case.current?.isParameterized
        )
    }
}

/// Metadata is a trailing JSON field, leaving existing log payloads intact.
/// Clock.swift:29-33 uses CLOCK_UPTIME_RAW for the v0 stream's absolute instant;
/// integer seconds/nanos retain its epoch without a wall-clock conversion.
struct TestEventLogObservation: Encodable {
    let seconds: Int64?
    let nanoseconds: Int?
    let identity: TestEventLogIdentity?
    let waiterID: UInt64?

    init(identity: TestEventLogIdentity?, waiterID: UInt64?) {
        var instant = timespec()
        if clock_gettime(CLOCK_UPTIME_RAW, &instant) == 0 {
            seconds = Int64(instant.tv_sec)
            nanoseconds = instant.tv_nsec
        } else {
            seconds = nil
            nanoseconds = nil
        }
        self.identity = TestEventLogIdentity.current ?? identity
        self.waiterID = waiterID
    }

    private enum CodingKeys: String, CodingKey {
        case clockDomain, seconds, nanoseconds, testID, caseID, parameterized, waiterID
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode("CLOCK_UPTIME_RAW", forKey: .clockDomain)
        try fields.encode(seconds, forKey: .seconds)
        try fields.encode(nanoseconds, forKey: .nanoseconds)
        try fields.encode(identity?.testID, forKey: .testID)
        try fields.encodeNil(forKey: .caseID)
        try fields.encode(identity?.parameterized, forKey: .parameterized)
        try fields.encode(waiterID, forKey: .waiterID)
    }
}
