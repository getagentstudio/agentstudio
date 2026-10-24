import Foundation

// Wire tags follow the pinned swift-otel OpenTelemetry metrics/common schemas.
// Decode received bytes, rather than searching strings that could also occur in logs.
enum OTLPProtobufTestDecoder {
    struct GaugePoint: Sendable {
        let name: String
        let value: Double
        let attributes: [String: String]
        let resourceAttributes: [String: String]
    }

    static func gaugePoints(in data: Data) throws -> [GaugePoint] {
        var points: [GaugePoint] = []
        for resourceBytes in try Message(data).messages(1) {
            let resourceMetrics = try Message(resourceBytes)
            let resource =
                try resourceMetrics.messages(1).first.map { try stringAttributes(Message($0), field: 1) } ?? [:]
            for scopeBytes in try resourceMetrics.messages(2) {
                for metricBytes in try Message(scopeBytes).messages(2) {
                    let metric = try Message(metricBytes)
                    let name = try metric.string(1)
                    for gaugeBytes in try metric.messages(5) {
                        for pointBytes in try Message(gaugeBytes).messages(1) {
                            let point = try Message(pointBytes)
                            let value: Double
                            if case .fixed64(let bits)? = point.fields[4]?.first {
                                value = Double(bitPattern: bits)
                            } else if case .fixed64(let bits)? = point.fields[6]?.first {
                                value = Double(Int64(bitPattern: bits))
                            } else {
                                throw DecodeError.malformed("gauge \(name) has no numeric value")
                            }
                            points.append(
                                GaugePoint(
                                    name: name, value: value,
                                    attributes: try stringAttributes(point, field: 7), resourceAttributes: resource
                                )
                            )
                        }
                    }
                }
            }
        }
        return points
    }

    enum LogValue: Equatable, Sendable {
        case string(String)
        case stringArray([String])
    }

    struct LogRecord: Sendable {
        let body: String
        let attributes: [String: LogValue]
    }

    static func logRecords(in data: Data) throws -> [LogRecord] {
        var records: [LogRecord] = []
        for resourceBytes in try Message(data).messages(1) {
            for scopeBytes in try Message(resourceBytes).messages(2) {
                for recordBytes in try Message(scopeBytes).messages(2) {
                    let record = try Message(recordBytes)
                    let bodies = try record.messages(5)
                    guard bodies.count == 1 else { throw DecodeError.malformed("missing log body") }
                    var attributes: [String: LogValue] = [:]
                    for pairBytes in try record.messages(6) {
                        let pair = try Message(pairBytes)
                        let values = try pair.messages(2)
                        guard values.count == 1 else { throw DecodeError.malformed("missing log value") }
                        attributes[try pair.string(1)] = try logValue(Message(values[0]))
                    }
                    records.append(LogRecord(body: try Message(bodies[0]).string(1), attributes: attributes))
                }
            }
        }
        return records
    }

    private static func logValue(_ value: Message) throws -> LogValue {
        if value.fields[1] != nil { return .string(try value.string(1)) }
        let arrays = try value.messages(5)
        guard arrays.count == 1 else { throw DecodeError.malformed("expected string or string array") }
        return .stringArray(try Message(arrays[0]).messages(1).map { try Message($0).string(1) })
    }

    private static func stringAttributes(_ message: Message, field: Int) throws -> [String: String] {
        var attributes: [String: String] = [:]
        for bytes in try message.messages(field) {
            let pair = try Message(bytes)
            let values = try pair.messages(2)
            guard values.count == 1 else { throw DecodeError.malformed("attribute has no single AnyValue") }
            attributes[try pair.string(1)] = try Message(values[0]).string(1)
        }
        return attributes
    }

    private enum WireValue {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt64)
    }

    private struct Message {
        var fields: [Int: [WireValue]] = [:]

        init(_ data: Data) throws {
            let bytes = Array(data)
            var offset = 0
            while offset < bytes.count {
                let tag = try Self.varint(bytes, offset: &offset)
                guard tag >> 3 > 0, tag >> 3 <= UInt64(Int.max) else {
                    throw DecodeError.malformed("invalid field tag")
                }
                let value: WireValue
                switch tag & 7 {
                case 0: value = .varint(try Self.varint(bytes, offset: &offset))
                case 1: value = .fixed64(try Self.fixed(bytes, offset: &offset, count: 8))
                case 2:
                    let length = try Self.varint(bytes, offset: &offset)
                    guard length <= UInt64(bytes.count - offset) else {
                        throw DecodeError.malformed("truncated message")
                    }
                    let end = offset + Int(length)
                    value = .bytes(Data(bytes[offset..<end]))
                    offset = end
                case 5: value = .fixed32(try Self.fixed(bytes, offset: &offset, count: 4))
                default: throw DecodeError.malformed("unsupported wire type")
                }
                fields[Int(tag >> 3), default: []].append(value)
            }
        }

        func messages(_ field: Int) throws -> [Data] {
            try (fields[field] ?? []).map { value in
                guard case .bytes(let bytes) = value else { throw DecodeError.malformed("expected message") }
                return bytes
            }
        }

        func string(_ field: Int) throws -> String {
            let values = try messages(field)
            guard values.count == 1, let string = String(data: values[0], encoding: .utf8) else {
                throw DecodeError.malformed("expected UTF-8 string")
            }
            return string
        }

        private static func varint(_ bytes: [UInt8], offset: inout Int) throws -> UInt64 {
            var value: UInt64 = 0
            // Ten bytes is the protobuf uint64 wire bound, not a waiting budget.
            for index in 0..<10 {
                guard offset < bytes.count else { throw DecodeError.malformed("truncated varint") }
                let byte = bytes[offset]
                offset += 1
                guard index < 9 || byte <= 1 else { throw DecodeError.malformed("varint overflow") }
                value |= UInt64(byte & 0x7f) << (7 * index)
                if byte & 0x80 == 0 { return value }
            }
            throw DecodeError.malformed("varint overflow")
        }

        private static func fixed(_ bytes: [UInt8], offset: inout Int, count: Int) throws -> UInt64 {
            guard bytes.count - offset >= count else { throw DecodeError.malformed("truncated fixed value") }
            var value: UInt64 = 0
            for index in 0..<count { value |= UInt64(bytes[offset + index]) << (8 * index) }
            offset += count
            return value
        }
    }

    private enum DecodeError: Error {
        case malformed(String)
    }
}
