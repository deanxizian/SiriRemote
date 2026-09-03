import Foundation

private func fail(_ message: String) -> Never {
    fputs("parser test: \(message)\n", stderr)
    exit(1)
}

private func littleEndian16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8)]
}

private func bigEndian32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func aclPacket(handle: UInt16, packetBoundary: UInt16, data: [UInt8],
                       declaredLength: Int? = nil) -> [UInt8] {
    littleEndian16(handle | packetBoundary)
        + littleEndian16(UInt16(declaredLength ?? data.count))
        + data
}

private func pklgRecord(_ acl: [UInt8]) -> [UInt8] {
    let length = UInt32(9 + acl.count)
    return bigEndian32(length)
        + bigEndian32(1_700_000_000)
        + bigEndian32(123_456)
        + [0x03]
        + acl
}

private func testPklgSegmentationAndRecovery() {
    let att: [UInt8] = [
        0x1B, 0x35, 0x00,             // ATT notification + dynamic attribute handle
        0xCA, 0x5B, 0x34, 0x12,       // stream marker + sequence
        0x03, 0xB8, 0xAA, 0xBB,       // Opus length + payload
    ]
    let l2cap = littleEndian16(UInt16(att.count)) + [0x04, 0x00] + att
    let split = 8
    let first = aclPacket(handle: 0x02A2, packetBoundary: 0x2000,
                          data: Array(l2cap[..<split]))
    let continuation = aclPacket(handle: 0x02A2, packetBoundary: 0x1000,
                                 data: Array(l2cap[split...]))
    let bytes = pklgRecord(first) + pklgRecord(continuation)

    let segmented = PklgVoiceExtractor()
    var frames: [RemoteVoiceFrame] = []
    var offset = 0
    let chunkSizes = [1, 2, 5, 3, 11, 4, 7, 13]
    var chunkIndex = 0
    while offset < bytes.count {
        let size = min(chunkSizes[chunkIndex % chunkSizes.count], bytes.count - offset)
        frames.append(contentsOf: segmented.ingest(Data(bytes[offset..<(offset + size)])))
        offset += size
        chunkIndex += 1
    }
    guard frames.count == 1, frames[0].sequence == 0x1234,
          frames[0].attributeHandle == 0x0035,
          Array(frames[0].opusPayload) == [0xB8, 0xAA, 0xBB] else {
        fail("segmented .pklg records did not reassemble exactly one voice frame")
    }

    let recovered = PklgVoiceExtractor()
    let corruptPrefix = [UInt8](repeating: 0xFF, count: 5)
    let recoveredFrames = recovered.ingest(Data(corruptPrefix + bytes))
    guard recoveredFrames.count == 1, recoveredFrames[0].sequence == 0x1234 else {
        fail("extractor did not resynchronize after corrupt record length")
    }

    let truncated = PklgVoiceExtractor()
    let invalidACL = aclPacket(handle: 0x02A2, packetBoundary: 0x2000,
                               data: Array(l2cap.prefix(4)), declaredLength: 40)
    guard truncated.ingest(Data(pklgRecord(invalidACL))).isEmpty else {
        fail("truncated ACL payload was accepted")
    }
}

private func testSequenceRecovery() {
    var tracker = VoiceSequenceTracker()
    guard tracker.observe(100) == .first,
          tracker.observe(101) == .next,
          tracker.observe(101) == .duplicate,
          tracker.observe(104) == .conceal(2),
          tracker.observe(200) == .discontinuity else {
        fail("sequence duplicate/gap/discontinuity policy mismatch")
    }
    var wrapping = VoiceSequenceTracker()
    guard wrapping.observe(UInt16.max) == .first,
          wrapping.observe(0) == .next else {
        fail("sequence wraparound was treated as packet loss")
    }
}

@main
enum VoiceFrameParserTest {
    static func main() {
        let valid = "Jul 23 15:45:23.502  Siri Remote  0x04A2  RECV  "
            + "06 24 0E 00 0A 00 04 00 1B 35 00 CA 5B 34 12 03 B8 AA BB"
        guard let frame = VoiceFrameParser.parse(valid) else { fail("valid frame rejected") }
        guard frame.connectionHandle == "0x04A2" else { fail("dynamic handle not retained") }
        guard frame.attributeHandle == 0x0035 else { fail("ATT handle not retained") }
        guard frame.sequence == 0x1234 else { fail("sequence decoded as \(frame.sequence)") }
        guard Array(frame.opusPayload) == [0xB8, 0xAA, 0xBB] else { fail("payload mismatch") }

        let alternateHandle = valid.replacingOccurrences(of: "1B 35 00", with: "1B 36 00")
        guard let alternateFrame = VoiceFrameParser.parse(alternateHandle)
        else { fail("firmware-dependent ATT handle rejected") }
        guard alternateFrame.sequence == 0x1234 else { fail("alternate-handle sequence mismatch") }
        guard Array(alternateFrame.opusPayload) == [0xB8, 0xAA, 0xBB]
        else { fail("alternate-handle payload mismatch") }

        guard VoiceFrameParser.parse(valid.replacingOccurrences(of: "RECV", with: "SEND")) == nil
        else { fail("SEND packet accepted") }
        let dynamicATT = valid.replacingOccurrences(of: "1B 35 00", with: "1B 37 00")
        guard let dynamicFrame = VoiceFrameParser.parse(dynamicATT),
              dynamicFrame.attributeHandle == 0x0037 else {
            fail("structurally valid dynamic ATT handle rejected")
        }
        guard VoiceFrameParser.parse(String(valid.dropLast(3))) == nil
        else { fail("truncated packet accepted") }
        guard VoiceFrameParser.parse(valid.replacingOccurrences(of: "B8 AA BB", with: "78 AA BB")) == nil
        else { fail("wrong Opus TOC accepted") }
        let alternateHeader = valid.replacingOccurrences(of: "CA 5B", with: "21 7E")
        guard let alternateHeaderFrame = VoiceFrameParser.parse(alternateHeader),
              alternateHeaderFrame.sequence == 0x1234 else {
            fail("firmware/session-specific A2854 header was incorrectly rejected")
        }

        testPklgSegmentationAndRecovery()
        testSequenceRecovery()

        print("parser test: PASS")
    }
}
