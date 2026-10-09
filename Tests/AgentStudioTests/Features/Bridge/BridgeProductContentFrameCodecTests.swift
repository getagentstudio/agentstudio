import Foundation
import Testing

@testable import AgentStudioBridge

struct BridgeProductContentFrameCodecTests {
    @Test("content wire repeats full binding identity only in accepted")
    func contentWireUsesMinimalTagSpecificBodies() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let dataObject = try fixtureHeaderObject(kind: "content.data")
        let endObject = try fixtureHeaderObject(kind: "content.end")
        let accepted = try BridgeProductContentFrameCodec.encode(
            .init(header: try decodeHeader(acceptedObject), payload: Data())
        )
        let data = try BridgeProductContentFrameCodec.encode(
            .init(header: try decodeHeader(dataObject), payload: Data("abc".utf8))
        )
        let end = try BridgeProductContentFrameCodec.encode(
            .init(header: try decodeHeader(endObject), payload: Data())
        )
        let expectedAccepted = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        let expectedEnd = try minimalControlFrame(
            tag: 0x03,
            sequence: 2,
            bodyObject: endControlBody(from: endObject)
        )

        #expect(accepted == expectedAccepted)
        #expect(data == minimalDataFrame(sequence: 1, offsetBytes: 0, payload: Data("abc".utf8)))
        #expect(end == expectedEnd)
        #expect(readUInt32BigEndian(accepted, offset: 5) == 0)
        #expect(readUInt32BigEndian(data, offset: 5) == 1)
        #expect(readUInt32BigEndian(data, offset: 9) == 0)
        guard case .end(let decodedEnd) = try decodeHeader(endObject) else {
            Issue.record("Expected content.end header")
            return
        }
        #expect(decodedEnd.endOfSource)

        let identityMarker = Data("file-descriptor-1".utf8)
        #expect(byteSubsequenceCount(identityMarker, in: accepted) == 1)
        #expect(byteSubsequenceCount(identityMarker, in: data) == 0)
        #expect(byteSubsequenceCount(identityMarker, in: end) == 0)
    }

    @Test("content decoder accepts independently constructed minimal frames")
    func contentDecoderAcceptsIndependentMinimalFrames() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let dataObject = try fixtureHeaderObject(kind: "content.data")
        let endObject = try fixtureHeaderObject(kind: "content.end")
        let acceptedWire = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        let dataWire = minimalDataFrame(
            sequence: 1,
            offsetBytes: 0,
            payload: Data("abc".utf8)
        )
        let endWire = try minimalControlFrame(
            tag: 0x03,
            sequence: 2,
            bodyObject: endControlBody(from: endObject)
        )
        var wireBytes = acceptedWire
        wireBytes.append(dataWire)
        wireBytes.append(endWire)
        let decoder = try BridgeProductContentFrameDecoder()

        #expect(try decoder.append(wireBytes.prefix(3)).isEmpty)
        let decodedFrames = try decoder.append(wireBytes.dropFirst(3))
        try decoder.finish()

        #expect(
            decodedFrames
                == [
                    .init(header: try decodeHeader(acceptedObject), payload: Data()),
                    .init(header: try decodeHeader(dataObject), payload: Data("abc".utf8)),
                    .init(header: try decodeHeader(endObject), payload: Data()),
                ]
        )
    }

    @Test("content acceptance binds derivation epoch while later frames inherit stream context")
    func contentAcceptanceBindsDerivationEpochAndLaterFramesInherit() throws {
        let requestObject = surfaceContentObject(
            try fixtureContentRequestObject(),
            derivationEpoch: 3
        )
        let acceptedObject = surfaceContentObject(
            try fixtureHeaderObject(kind: "content.accepted"),
            derivationEpoch: 3
        )
        let request = decodedContentRequest(requestObject)
        let accepted = decodedContentHeader(acceptedObject)

        #expect(request != nil)
        #expect(accepted != nil)
        var missingEpochRequest = requestObject
        missingEpochRequest.removeValue(forKey: "workerDerivationEpoch")
        #expect(contentDecodingFails(BridgeProductContentRequest.self, object: missingEpochRequest))
        var legacyEpochRequest = missingEpochRequest
        legacyEpochRequest["workerEpoch"] = 3
        #expect(contentDecodingFails(BridgeProductContentRequest.self, object: legacyEpochRequest))
        var repeatedSurfaceRequest = requestObject
        repeatedSurfaceRequest["surface"] = "file"
        #expect(contentDecodingFails(BridgeProductContentRequest.self, object: repeatedSurfaceRequest))

        var missingEpochAccepted = acceptedObject
        missingEpochAccepted.removeValue(forKey: "workerDerivationEpoch")
        #expect(contentDecodingFails(BridgeProductContentHeader.self, object: missingEpochAccepted))
        var legacyEpochAccepted = missingEpochAccepted
        legacyEpochAccepted["workerEpoch"] = 3
        #expect(contentDecodingFails(BridgeProductContentHeader.self, object: legacyEpochAccepted))
        var repeatedSurfaceAccepted = acceptedObject
        repeatedSurfaceAccepted["surface"] = "file"
        #expect(contentDecodingFails(BridgeProductContentHeader.self, object: repeatedSurfaceAccepted))

        if let request, let accepted {
            var mismatchedAcceptedObject = acceptedObject
            mismatchedAcceptedObject["workerDerivationEpoch"] = 4
            let mismatchedAccepted = try #require(decodedContentHeader(mismatchedAcceptedObject))
            let mismatchedValidator = BridgeProductContentStreamValidator(expectedRequest: request)
            #expect(throws: (any Error).self) {
                _ = try mismatchedValidator.accept(
                    .init(header: mismatchedAccepted, payload: Data())
                )
            }

            var newerRequestObject = requestObject
            newerRequestObject["contentRequestId"] = "content-request-newer"
            newerRequestObject["leaseId"] = "lease-newer"
            newerRequestObject["workerDerivationEpoch"] = 19
            #expect(decodedContentRequest(newerRequestObject) != nil)

            let data = try fixtureHeader(kind: "content.data")
            let end = try fixtureHeader(kind: "content.end")
            let validator = BridgeProductContentStreamValidator(expectedRequest: request)
            _ = try validator.accept(.init(header: accepted, payload: Data()))
            _ = try validator.accept(.init(header: data, payload: Data("abc".utf8)))
            #expect(try validator.accept(.init(header: end, payload: Data())) != nil)
            try validator.finish()
        }

        for laterKind in ["content.data", "content.end", "content.error", "content.reset"] {
            let laterHeader = try fixtureHeaderObject(kind: laterKind)
            #expect(!contentDecodingFails(BridgeProductContentHeader.self, object: laterHeader))
            var withDerivationEpoch = laterHeader
            withDerivationEpoch["workerDerivationEpoch"] = 3
            #expect(contentDecodingFails(BridgeProductContentHeader.self, object: withDerivationEpoch))
            var withWorkerEpoch = laterHeader
            withWorkerEpoch["workerEpoch"] = 3
            #expect(contentDecodingFails(BridgeProductContentHeader.self, object: withWorkerEpoch))
        }
    }

    @Test("content decoder admits only bounded prefixes from hostile chunks")
    func contentDecoderAdmitsOnlyBoundedPrefixesFromHostileChunks() throws {
        var oversizedFrameChunk = dataWithUInt32Prefix(
            BridgeProductWireContract.maximumContentFrameBytes + 1
        )
        oversizedFrameChunk.append(Data(repeating: 0xa5, count: 4 * 1024 * 1024))
        let oversizedFrameDecoder = try BridgeProductContentFrameDecoder()

        #expect(throws: (any Error).self) {
            _ = try oversizedFrameDecoder.append(oversizedFrameChunk)
        }
        let oversizedFrameDiagnostics = oversizedFrameDecoder.diagnostics
        #expect(oversizedFrameDiagnostics.receivedByteCount == oversizedFrameChunk.count)
        #expect(oversizedFrameDiagnostics.consumedByteCount == 4)
        #expect(oversizedFrameDiagnostics.copiedByteCount == 4)
        #expect(oversizedFrameDiagnostics.retainedByteCount == 0)
        #expect(oversizedFrameDiagnostics.peakRetainedByteCount == 4)
        #expect(oversizedFrameDiagnostics.discardedTailByteCount == oversizedFrameChunk.count - 4)
        #expect(oversizedFrameDiagnostics.state == .poisoned)
        #expect(oversizedFrameDiagnostics.failureCode == .frameLengthExceedsCeiling)

        let oversizedControlBody = Data(
            repeating: 0x5a,
            count: BridgeProductWireContract.maximumContentControlBodyBytes + 1
        )
        var hostileControlChunk = minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            rawBody: oversizedControlBody
        )
        hostileControlChunk.append(Data(repeating: 0x5a, count: 4 * 1024 * 1024))
        let decoder = try BridgeProductContentFrameDecoder()

        #expect(throws: (any Error).self) {
            _ = try decoder.append(hostileControlChunk)
        }
        let headerDiagnostics = decoder.diagnostics
        #expect(headerDiagnostics.consumedByteCount == 9)
        #expect(headerDiagnostics.copiedByteCount == 9)
        #expect(headerDiagnostics.retainedByteCount == 0)
        #expect(headerDiagnostics.peakRetainedByteCount == 9)
        #expect(headerDiagnostics.discardedTailByteCount == hostileControlChunk.count - 9)
        #expect(headerDiagnostics.failureCode == .contentControlBodyExceedsCeiling)
    }

    @Test("content decoder copies one-byte and 4 KiB fragments without relocation")
    func contentDecoderCopiesFragmentsWithoutRelocation() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let endObject = try fixtureHeaderObject(kind: "content.end")
        var encoded = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        encoded.append(minimalDataFrame(sequence: 1, offsetBytes: 0, payload: Data("abc".utf8)))
        encoded.append(
            try minimalControlFrame(
                tag: 0x03,
                sequence: 2,
                bodyObject: endControlBody(from: endObject)
            )
        )
        let fragmentedDecoder = try BridgeProductContentFrameDecoder()
        var fragmentedFrames: [BridgeProductContentFrame] = []
        for byte in encoded {
            fragmentedFrames.append(contentsOf: try fragmentedDecoder.append(Data([byte])))
        }
        try fragmentedDecoder.finish()
        #expect(fragmentedFrames.count == 3)
        #expect(fragmentedDecoder.diagnostics.copiedByteCount == encoded.count)
        #expect(fragmentedDecoder.diagnostics.retainedByteCount == 0)
        #expect(fragmentedDecoder.diagnostics.emittedFrameCount == 3)
        #expect(fragmentedDecoder.diagnostics.state == .finished)
        #expect(fragmentedDecoder.storageDiagnostics.ingressCopiedByteCount == encoded.count)
        #expect(fragmentedDecoder.storageDiagnostics.relocationCopiedByteCount == 0)
        #expect(fragmentedDecoder.storageDiagnostics.allocationCount == 7)

        let maximumPayload = Data(repeating: 0xa5, count: 128 * 1024)
        let largeObjects = try contentHeaderObjects(
            declaredByteLength: maximumPayload.count,
            maximumBytes: maximumPayload.count
        )
        var maximumWire = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: largeObjects.accepted)
        )
        maximumWire.append(minimalDataFrame(sequence: 1, offsetBytes: 0, payload: maximumPayload))
        maximumWire.append(
            try minimalControlFrame(
                tag: 0x03,
                sequence: 2,
                bodyObject: endControlBody(from: largeObjects.end)
            )
        )
        let maximumDecoder = try BridgeProductContentFrameDecoder()
        var maximumDecodedFrameCount = 0
        for offset in stride(from: 0, to: maximumWire.count, by: 4096) {
            maximumDecodedFrameCount += try maximumDecoder.append(
                maximumWire[offset..<min(offset + 4096, maximumWire.count)]
            ).count
        }
        try maximumDecoder.finish()
        #expect(maximumDecodedFrameCount == 3)
        #expect(maximumDecoder.diagnostics.copiedByteCount == maximumWire.count)
        #expect(maximumDecoder.diagnostics.retainedByteCount == 0)
        #expect(maximumDecoder.storageDiagnostics.ingressCopiedByteCount == maximumWire.count)
        #expect(maximumDecoder.storageDiagnostics.relocationCopiedByteCount == 0)
        #expect(maximumDecoder.storageDiagnostics.allocationCount == 7)
    }

    @Test("content data fills the frame after its header and rejects one byte more")
    func contentDataCapAccountsForItsFrameHeader() throws {
        let maximumPayload = Data(repeating: 0x61, count: 256 * 1024 - 42)
        let oversizedPayload = Data(repeating: 0x62, count: maximumPayload.count + 1)
        let maximumObjects = try contentHeaderObjects(
            declaredByteLength: maximumPayload.count,
            maximumBytes: maximumPayload.count
        )
        #expect(throws: Never.self) {
            _ = try BridgeProductContentFrameCodec.encode(
                .init(header: try decodeHeader(maximumObjects.data), payload: maximumPayload)
            )
        }
        #expect(throws: (any Error).self) {
            _ = try BridgeProductContentFrameCodec.encode(
                .init(header: try decodeHeader(maximumObjects.data), payload: oversizedPayload)
            )
        }

        let acceptedWire = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: maximumObjects.accepted)
        )
        let maximumDecoder = try BridgeProductContentFrameDecoder()
        #expect(
            try maximumDecoder.append(
                acceptedWire
                    + minimalDataFrame(sequence: 1, offsetBytes: 0, payload: maximumPayload)
            ).count == 2
        )
        let oversizedDecoder = try BridgeProductContentFrameDecoder()
        #expect(throws: (any Error).self) {
            _ = try oversizedDecoder.append(
                acceptedWire
                    + minimalDataFrame(sequence: 1, offsetBytes: 0, payload: oversizedPayload)
            )
        }
        #expect(oversizedDecoder.diagnostics.emittedFrameCount == 0)
        #expect(oversizedDecoder.diagnostics.state == .poisoned)
    }

    @Test("two MiB content uses sixteen full data frames plus accepted and end")
    func twoMiBContentUsesSixteenDataFrames() throws {
        let payloadByteCount = 128 * 1024
        let totalByteCount = 2 * 1024 * 1024
        let objects = try contentHeaderObjects(
            declaredByteLength: totalByteCount,
            maximumBytes: totalByteCount
        )
        var frames = [
            try BridgeProductContentFrameCodec.encode(
                .init(header: try decodeHeader(objects.accepted), payload: Data())
            )
        ]
        for index in 0..<16 {
            var dataObject = objects.data
            dataObject["contentSequence"] = index + 1
            dataObject["offsetBytes"] = index * payloadByteCount
            frames.append(
                try BridgeProductContentFrameCodec.encode(
                    .init(
                        header: try decodeHeader(dataObject),
                        payload: Data(repeating: UInt8(index), count: payloadByteCount)
                    )
                )
            )
        }
        var endObject = objects.end
        endObject["contentSequence"] = 17
        frames.append(
            try BridgeProductContentFrameCodec.encode(
                .init(header: try decodeHeader(endObject), payload: Data())
            )
        )

        #expect(frames.count == 18)
        for (index, dataFrame) in frames.dropFirst().dropLast().enumerated() {
            #expect(readUInt32BigEndian(dataFrame, offset: 0) == 1 + 4 + 4 + 33 + payloadByteCount)
            #expect(dataFrame[4] == 0x02)
            #expect(readUInt32BigEndian(dataFrame, offset: 5) == index + 1)
            #expect(readUInt32BigEndian(dataFrame, offset: 9) == index * payloadByteCount)
            #expect(dataFrame.count == 4 + 1 + 4 + 4 + 33 + payloadByteCount)
        }
    }

    @Test("content decoder accepts a partial final data frame")
    func contentDecoderAcceptsPartialFinalDataFrame() throws {
        let maximumPayload = Data(repeating: 0x61, count: 128 * 1024)
        let finalPayload = Data("abc".utf8)
        let totalByteCount = maximumPayload.count + finalPayload.count
        let objects = try contentHeaderObjects(
            declaredByteLength: totalByteCount,
            maximumBytes: totalByteCount
        )
        var wire = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: objects.accepted)
        )
        wire.append(minimalDataFrame(sequence: 1, offsetBytes: 0, payload: maximumPayload))
        wire.append(
            minimalDataFrame(
                sequence: 2,
                offsetBytes: maximumPayload.count,
                payload: finalPayload
            )
        )
        wire.append(
            try minimalControlFrame(
                tag: 0x03,
                sequence: 3,
                bodyObject: endControlBody(from: objects.end)
            )
        )
        let decoder = try BridgeProductContentFrameDecoder()

        let decodedFrames = try decoder.append(wire)
        try decoder.finish()

        #expect(decodedFrames.count == 4)
        #expect(decodedFrames[2].payload == finalPayload)
    }

    @Test("content decoder poisons atomically on lifecycle misuse")
    func contentDecoderPoisonsAtomicallyOnLifecycleMisuse() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let endObject = try fixtureHeaderObject(kind: "content.end")
        let accepted = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        let misuseChunks = [
            minimalDataFrame(sequence: 1, offsetBytes: 0, payload: Data("abc".utf8)),
            accepted + minimalDataFrame(sequence: 2, offsetBytes: 0, payload: Data("abc".utf8)),
            accepted + minimalDataFrame(sequence: 1, offsetBytes: 1, payload: Data("abc".utf8)),
            try accepted
                + minimalControlFrame(
                    tag: 0x03,
                    sequence: 1,
                    bodyObject: endControlBody(from: endObject)
                )
                + minimalDataFrame(sequence: 2, offsetBytes: 0, payload: Data("abc".utf8)),
        ]

        for misuseChunk in misuseChunks {
            let decoder = try BridgeProductContentFrameDecoder()
            #expect(throws: (any Error).self) {
                _ = try decoder.append(misuseChunk)
            }
            #expect(decoder.diagnostics.emittedFrameCount == 0)
            #expect(decoder.diagnostics.retainedByteCount == 0)
            #expect(decoder.diagnostics.state == .poisoned)
        }
    }

    @Test("content decoder rejects coalesced and later one-byte terminal tails")
    func contentDecoderRejectsOneByteTerminalTails() throws {
        let objects = try contentHeaderObjects(
            declaredByteLength: 0,
            maximumBytes: 0
        )
        let accepted = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: objects.accepted)
        )
        let end = try minimalControlFrame(
            tag: 0x03,
            sequence: 1,
            bodyObject: endControlBody(from: objects.end)
        )
        let coalescedDecoder = try BridgeProductContentFrameDecoder()

        #expect(throws: (any Error).self) {
            _ = try coalescedDecoder.append(accepted + end + Data([0xa5]))
        }
        #expect(coalescedDecoder.diagnostics.emittedFrameCount == 0)
        #expect(coalescedDecoder.diagnostics.discardedTailByteCount == 1)
        #expect(coalescedDecoder.diagnostics.retainedByteCount == 0)

        let laterDecoder = try BridgeProductContentFrameDecoder()
        #expect(try laterDecoder.append(accepted).count == 1)
        #expect(try laterDecoder.append(end).count == 1)
        let allocationCountBeforeTail = laterDecoder.storageDiagnostics.allocationCount
        #expect(throws: (any Error).self) {
            _ = try laterDecoder.append(Data([0xa5]))
        }
        #expect(laterDecoder.storageDiagnostics.allocationCount == allocationCountBeforeTail)
        #expect(laterDecoder.diagnostics.discardedTailByteCount == 1)
        #expect(laterDecoder.diagnostics.retainedByteCount == 0)
    }

    @Test("content decoder rejects duplicate control members and malformed frames")
    func contentDecoderRejectsDuplicateControlMembersAndMalformedFrames() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let acceptedJSON = try sortedJSONObjectData(acceptedControlBody(from: acceptedObject))
        let acceptedString = try #require(String(data: acceptedJSON, encoding: .utf8))
        let duplicateAccepted = acceptedString.replacingOccurrences(
            of: #""workerDerivationEpoch":"#,
            with: #""workerDerivationEpoch":999,"workerDerivationEpoch":"#
        )
        let decoder = try BridgeProductContentFrameDecoder()
        #expect(throws: (any Error).self) {
            _ = try decoder.append(
                minimalControlFrame(
                    tag: 0x01,
                    sequence: 0,
                    rawBody: Data(duplicateAccepted.utf8)
                )
            )
        }
        #expect(decoder.diagnostics.failureCode == .frameDecodeInvalid)
        #expect(decoder.diagnostics.emittedFrameCount == 0)

        var unknownTag = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        unknownTag[4] = 0xff
        let poisonedDecoder = try BridgeProductContentFrameDecoder()
        #expect(throws: (any Error).self) {
            _ = try poisonedDecoder.append(unknownTag)
        }
        #expect(throws: (any Error).self) {
            _ = try poisonedDecoder.append(unknownTag)
        }

        let validAccepted = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        let truncatedDecoder = try BridgeProductContentFrameDecoder()
        #expect(try truncatedDecoder.append(validAccepted.dropLast()).isEmpty)
        #expect(throws: (any Error).self) {
            try truncatedDecoder.finish()
        }
        #expect(truncatedDecoder.diagnostics.failureCode == .truncatedFrame)
    }

    @Test("content decoder owns staged and emitted raw data bytes")
    func contentDecoderOwnsStagedAndEmittedRawDataBytes() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let accepted = try minimalControlFrame(
            tag: 0x01,
            sequence: 0,
            bodyObject: acceptedControlBody(from: acceptedObject)
        )
        var data = minimalDataFrame(sequence: 1, offsetBytes: 0, payload: Data("abc".utf8))
        let stagedPrefix = data.dropLast()
        let finalByte = data.suffix(1)
        let decoder = try BridgeProductContentFrameDecoder()

        #expect(try decoder.append(accepted).count == 1)
        #expect(try decoder.append(stagedPrefix).isEmpty)
        let decodedFrame = try #require(try decoder.append(finalByte).first)
        data.resetBytes(in: 0..<data.count)

        #expect(decodedFrame.payload == Data("abc".utf8))
    }

    @Test("content encoder owns one request and poisons atomically after misuse")
    func contentEncoderOwnsOneRequestAndPoisonsAtomicallyAfterMisuse() throws {
        let request = try fixtureContentRequest()
        let accepted = BridgeProductContentFrame(
            header: try fixtureHeader(kind: "content.accepted"),
            payload: Data()
        )
        let data = BridgeProductContentFrame(
            header: try fixtureHeader(kind: "content.data"),
            payload: Data("abc".utf8)
        )
        let end = BridgeProductContentFrame(
            header: try fixtureHeader(kind: "content.end"),
            payload: Data()
        )
        var foreignAcceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        foreignAcceptedObject["contentRequestId"] = "content-request-foreign"
        let foreignEncoder = BridgeProductContentFrameEncoder(expectedRequest: request)
        var foreignEmissions: [Data] = []

        #expect(throws: (any Error).self) {
            foreignEmissions.append(
                try foreignEncoder.encode(
                    .init(header: try decodeHeader(foreignAcceptedObject), payload: Data())
                )
            )
        }
        #expect(foreignEmissions.isEmpty)
        #expect(throws: (any Error).self) { _ = try foreignEncoder.encode(accepted) }

        let preAcceptedEncoder = BridgeProductContentFrameEncoder(expectedRequest: request)
        #expect(throws: (any Error).self) { _ = try preAcceptedEncoder.encode(data) }
        #expect(throws: (any Error).self) { _ = try preAcceptedEncoder.encode(accepted) }
        #expect(throws: (any Error).self) { try preAcceptedEncoder.finish() }

        let duplicateEncoder = BridgeProductContentFrameEncoder(expectedRequest: request)
        _ = try duplicateEncoder.encode(accepted)
        #expect(throws: (any Error).self) { _ = try duplicateEncoder.encode(accepted) }
        #expect(throws: (any Error).self) { _ = try duplicateEncoder.encode(data) }

        var gapObject = try fixtureHeaderObject(kind: "content.data")
        gapObject["contentSequence"] = 2
        let gapEncoder = BridgeProductContentFrameEncoder(expectedRequest: request)
        _ = try gapEncoder.encode(accepted)
        #expect(throws: (any Error).self) {
            _ = try gapEncoder.encode(
                .init(header: try decodeHeader(gapObject), payload: Data("abc".utf8))
            )
        }
        #expect(throws: (any Error).self) { _ = try gapEncoder.encode(data) }

        var offsetObject = try fixtureHeaderObject(kind: "content.data")
        offsetObject["offsetBytes"] = 1
        let offsetEncoder = BridgeProductContentFrameEncoder(expectedRequest: request)
        _ = try offsetEncoder.encode(accepted)
        #expect(throws: (any Error).self) {
            _ = try offsetEncoder.encode(
                .init(header: try decodeHeader(offsetObject), payload: Data("abc".utf8))
            )
        }
        #expect(throws: (any Error).self) { _ = try offsetEncoder.encode(data) }

        let postTerminalEncoder = BridgeProductContentFrameEncoder(expectedRequest: request)
        _ = try postTerminalEncoder.encode(accepted)
        _ = try postTerminalEncoder.encode(data)
        _ = try postTerminalEncoder.encode(end)
        try postTerminalEncoder.finish()
        #expect(throws: (any Error).self) { _ = try postTerminalEncoder.encode(data) }
        #expect(throws: (any Error).self) { try postTerminalEncoder.finish() }
    }

    @Test("content stream validates exact length, digest, identity, and terminal state")
    func contentStreamValidatesExactLengthDigestIdentityAndTerminalState() throws {
        let accepted = try fixtureHeader(kind: "content.accepted")
        let data = try fixtureHeader(kind: "content.data")
        let end = try fixtureHeader(kind: "content.end")
        let validator = BridgeProductContentStreamValidator(expectedRequest: try fixtureContentRequest())

        #expect(try validator.accept(.init(header: accepted, payload: Data())) == nil)
        #expect(try validator.accept(.init(header: data, payload: Data("abc".utf8))) == nil)
        let terminal = try validator.accept(.init(header: end, payload: Data()))
        #expect(
            terminal
                == .complete(
                    .init(
                        bytes: Data("abc".utf8),
                        contentKind: .fileContent,
                        descriptorId: "file-descriptor-1",
                        endOfSource: true,
                        observedSha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                    )
                )
        )
        #expect(throws: (any Error).self) {
            _ = try validator.accept(.init(header: end, payload: Data()))
        }
        try validator.finish()
    }

    @Test("content stream rejects gaps, offset drift, bounds, and digest conflicts")
    func contentStreamRejectsLifecycleInvariantViolations() throws {
        let acceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        let dataObject = try fixtureHeaderObject(kind: "content.data")
        let endObject = try fixtureHeaderObject(kind: "content.end")
        let accepted = try decodeHeader(acceptedObject)
        let data = try decodeHeader(dataObject)
        let payload = Data("abc".utf8)

        let missingAccepted = BridgeProductContentStreamValidator(
            expectedRequest: try fixtureContentRequest()
        )
        #expect(throws: (any Error).self) {
            _ = try missingAccepted.accept(.init(header: data, payload: payload))
        }

        var sequenceGapObject = dataObject
        sequenceGapObject["contentSequence"] = 2
        try expectValidatorRejects(
            accepted: accepted,
            next: try decodeHeader(sequenceGapObject),
            payload: payload
        )

        var offsetDriftObject = dataObject
        offsetDriftObject["offsetBytes"] = 1
        try expectValidatorRejects(
            accepted: accepted,
            next: try decodeHeader(offsetDriftObject),
            payload: payload
        )

        var declaredLimitObject = acceptedObject
        declaredLimitObject["declaredByteLength"] = 2
        declaredLimitObject["maximumBytes"] = 2
        var declaredLimitIdentity = try #require(declaredLimitObject["identity"] as? [String: Any])
        var declaredLimitWindow = try #require(declaredLimitIdentity["window"] as? [String: Any])
        declaredLimitWindow["maximumBytes"] = 2
        declaredLimitIdentity["window"] = declaredLimitWindow
        declaredLimitObject["identity"] = declaredLimitIdentity
        var declaredLimitDataObject = dataObject
        if declaredLimitDataObject["identity"] != nil {
            try updateIdentityMaximumBytes(2, in: &declaredLimitDataObject)
        }
        var declaredLimitRequestObject = try fixtureContentRequestObject()
        var declaredLimitDescriptor = try #require(
            declaredLimitRequestObject["descriptor"] as? [String: Any]
        )
        declaredLimitDescriptor["declaredByteLength"] = 2
        declaredLimitDescriptor["maximumBytes"] = 2
        var declaredLimitRequestWindow = try #require(
            declaredLimitDescriptor["window"] as? [String: Any]
        )
        declaredLimitRequestWindow["maximumBytes"] = 2
        declaredLimitDescriptor["window"] = declaredLimitRequestWindow
        declaredLimitRequestObject["descriptor"] = declaredLimitDescriptor
        try expectValidatorRejects(
            expectedRequest: try decodeContentRequest(declaredLimitRequestObject),
            accepted: try decodeHeader(declaredLimitObject),
            next: try decodeHeader(declaredLimitDataObject),
            payload: payload
        )

        var observedLengthObject = endObject
        observedLengthObject["observedByteLength"] = 2
        try expectEndRejects(
            accepted: accepted,
            data: data,
            end: try decodeHeader(observedLengthObject)
        )

        var digestConflictObject = endObject
        digestConflictObject["observedSha256"] = String(repeating: "0", count: 64)
        try expectEndRejects(
            accepted: accepted,
            data: data,
            end: try decodeHeader(digestConflictObject)
        )

        var expectedDigestObject = acceptedObject
        expectedDigestObject["expectedSha256"] = String(repeating: "0", count: 64)
        var expectedDigestRequestObject = try fixtureContentRequestObject()
        var expectedDigestDescriptor = try #require(
            expectedDigestRequestObject["descriptor"] as? [String: Any]
        )
        expectedDigestDescriptor["expectedSha256"] = String(repeating: "0", count: 64)
        expectedDigestRequestObject["descriptor"] = expectedDigestDescriptor
        try expectEndRejects(
            expectedRequest: try decodeContentRequest(expectedDigestRequestObject),
            accepted: try decodeHeader(expectedDigestObject),
            data: data,
            end: try decodeHeader(endObject)
        )
    }

    @Test("content stream binds acceptance to its request and poisons after failure")
    func contentStreamBindsAcceptanceToRequestAndPoisonsAfterFailure() throws {
        let expectedRequest = try fixtureContentRequest()
        let accepted = try fixtureHeader(kind: "content.accepted")
        var foreignAcceptedObject = try fixtureHeaderObject(kind: "content.accepted")
        foreignAcceptedObject["contentRequestId"] = "content-request-foreign"
        let foreignAccepted = try decodeHeader(foreignAcceptedObject)
        let validator = BridgeProductContentStreamValidator(expectedRequest: expectedRequest)

        #expect(throws: (any Error).self) {
            _ = try validator.accept(.init(header: foreignAccepted, payload: Data()))
        }
        #expect(throws: (any Error).self) {
            _ = try validator.accept(.init(header: accepted, payload: Data()))
        }
        #expect(throws: (any Error).self) {
            try validator.finish()
        }
    }

    @Test("content stream and decoder reject clean EOF before a terminal frame")
    func contentStreamRejectsCleanEOFBeforeTerminalFrame() throws {
        let validator = BridgeProductContentStreamValidator(
            expectedRequest: try fixtureContentRequest()
        )
        let accepted = try fixtureHeader(kind: "content.accepted")
        let data = try fixtureHeader(kind: "content.data")

        _ = try validator.accept(.init(header: accepted, payload: Data()))
        #expect(throws: (any Error).self) {
            try validator.finish()
        }
        #expect(throws: (any Error).self) {
            _ = try validator.accept(.init(header: data, payload: Data("abc".utf8)))
        }

        let acceptedWire = try BridgeProductContentFrameCodec.encode(
            .init(header: accepted, payload: Data())
        )
        let dataWire = try BridgeProductContentFrameCodec.encode(
            .init(header: data, payload: Data("abc".utf8))
        )
        for incompleteWire in [Data(), acceptedWire, acceptedWire + dataWire] {
            let decoder = try BridgeProductContentFrameDecoder()
            _ = try decoder.append(incompleteWire)
            #expect(throws: (any Error).self) {
                try decoder.finish()
            }
            #expect(decoder.diagnostics.state == .poisoned)
            #expect(decoder.diagnostics.retainedByteCount == 0)
        }
    }

    @Test("content error and reset are terminal and retain typed identity")
    func contentErrorAndResetAreTerminalAndRetainTypedIdentity() throws {
        let accepted = try fixtureHeader(kind: "content.accepted")
        let data = try fixtureHeader(kind: "content.data")
        let payload = Data("abc".utf8)

        let errorValidator = BridgeProductContentStreamValidator(
            expectedRequest: try fixtureContentRequest()
        )
        _ = try errorValidator.accept(.init(header: accepted, payload: Data()))
        _ = try errorValidator.accept(.init(header: data, payload: payload))
        let errorObject = try fixtureHeaderObject(kind: "content.error")
        let errorResult = try errorValidator.accept(
            .init(header: try decodeHeader(errorObject), payload: Data())
        )
        #expect(
            errorResult
                == .error(
                    .init(
                        code: .internal,
                        contentKind: .fileContent,
                        descriptorId: "file-descriptor-1",
                        retryable: false,
                        safeMessage: nil
                    )
                )
        )
        try errorValidator.finish()

        let resetValidator = BridgeProductContentStreamValidator(
            expectedRequest: try fixtureContentRequest()
        )
        _ = try resetValidator.accept(.init(header: accepted, payload: Data()))
        _ = try resetValidator.accept(.init(header: data, payload: payload))
        let resetObject = try fixtureHeaderObject(kind: "content.reset")
        let resetResult = try resetValidator.accept(
            .init(header: try decodeHeader(resetObject), payload: Data())
        )
        #expect(
            resetResult
                == .reset(
                    .init(
                        contentKind: .fileContent,
                        descriptorId: "file-descriptor-1",
                        reason: .staleSource,
                        retryable: true
                    )
                )
        )
        try resetValidator.finish()
    }

    private func surfaceContentObject(
        _ object: [String: Any],
        derivationEpoch: Int
    ) -> [String: Any] {
        var canonical = object
        canonical.removeValue(forKey: "workerEpoch")
        canonical["workerDerivationEpoch"] = derivationEpoch
        canonical.removeValue(forKey: "surface")
        return canonical
    }

    private func decodedContentRequest(
        _ object: [String: Any]
    ) -> BridgeProductContentRequest? {
        try? decodeContentRequest(object)
    }

    private func decodedContentHeader(
        _ object: [String: Any]
    ) -> BridgeProductContentHeader? {
        try? decodeHeader(object)
    }

    private func contentDecodingFails<CodableValue: Codable>(
        _ type: CodableValue.Type,
        object: [String: Any]
    ) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return true
        }
        return (try? JSONDecoder().decode(type, from: data)) == nil
    }

}

extension BridgeProductContentFrameCodecTests {
    @Test("production producer injects admitted correlation into every content frame")
    func productionProducerInjectsAdmittedCorrelationIntoEveryContentFrame() throws {
        let operationCorrelationID = String(repeating: "a", count: 64)
        var requestObject = try fixtureContentRequestObject()
        requestObject["operationCorrelationId"] = operationCorrelationID
        let request = try decodeContentRequest(requestObject)

        let encodedData = try BridgeProductProducerFrameValidator.encode(
            for: .content(request),
            sequence: 1,
            intent: .nonterminal
        ) { sequence in
            .content(
                .init(
                    header: try .data(contentSequence: sequence, offsetBytes: 0),
                    payload: Data("abc".utf8)
                )
            )
        }

        let encodedBytes = encodedData.data
        #expect(encodedBytes[13] == 1)
        #expect(
            encodedBytes[14..<46]
                == operationCorrelationEnvelope(operationCorrelationID).dropFirst()
        )
    }

    @Test("metadata is bounded at 128 KiB and content frames at 256 KiB")
    func everySwiftResponseFrameUsesSharedCeiling() {
        #expect(BridgeProductWireContract.maximumMetadataFrameBytes == 128 * 1024)
        #expect(BridgeProductWireContract.maximumContentFrameBytes == 256 * 1024)
        #expect(BridgeProductWireContract.maximumContentDataPayloadBytes == 256 * 1024 - 42)
    }
}
