import XCTest
@testable import OrielProtocol

final class FramingTests: XCTestCase {

    func testRoundTrip() {
        let payload = Data("hello world".utf8)
        var decoder = FrameDecoder()
        decoder.append(Framing.packet(type: .input, payload: payload))

        let message = decoder.next()
        XCTAssertEqual(message?.type, .input)
        XCTAssertEqual(message?.payload, payload)
        XCTAssertNil(decoder.next())
    }

    func testSurvivesArbitraryChunking() {
        let messages: [(MessageType, Data)] = [
            (.hello, Data("first".utf8)),
            (.videoFrame, Data(repeating: 0xAB, count: 5000)),
            (.input, Data("third".utf8))
        ]
        let stream = messages.reduce(into: Data()) { result, message in
            result.append(Framing.packet(type: message.0, payload: message.1))
        }

        var decoder = FrameDecoder()
        var received: [(MessageType, Data)] = []

        // Feed one byte at a time: the decoder must never guess at a short read.
        for byte in stream {
            decoder.append(Data([byte]))
            while let message = decoder.next() {
                received.append(message)
            }
        }

        XCTAssertEqual(received.count, messages.count)
        for (index, expected) in messages.enumerated() {
            XCTAssertEqual(received[index].0, expected.0)
            XCTAssertEqual(received[index].1, expected.1)
        }
    }

    func testMultipleMessagesInOneRead() {
        var stream = Data()
        for index in 0..<8 {
            stream.append(Framing.packet(type: .ping, payload: Data([UInt8(index)])))
        }

        var decoder = FrameDecoder()
        decoder.append(stream)

        var count = 0
        while decoder.next() != nil { count += 1 }
        XCTAssertEqual(count, 8)
    }

    func testZeroLengthMessageIsRejected() {
        // A length prefix of 0 describes a message with no type byte: the
        // decoder must not spin forever on it.
        var stream = Data()
        stream.append(contentsOf: [0, 0, 0, 0])
        var decoder = FrameDecoder()
        decoder.append(stream)
        XCTAssertNil(decoder.next())
    }

    func testOversizedMessageIsDropped() {
        var stream = Data()
        let length = UInt32(ProtocolLimits.maxMessageBytes + 1)
        stream.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Data($0) })
        var decoder = FrameDecoder()
        decoder.append(stream)
        XCTAssertNil(decoder.next())
        XCTAssertFalse(decoder.isDesynced, "buffer should be cleared after a bad length")
    }

    func testTruncatedMessageIsHeldNotDropped() {
        let full = Framing.packet(type: .input, payload: Data("partial".utf8))
        var decoder = FrameDecoder()
        decoder.append(full.prefix(full.count - 2))
        XCTAssertNil(decoder.next())
        decoder.append(full.suffix(2))
        XCTAssertEqual(decoder.next()?.payload, Data("partial".utf8))
    }
}

final class ViewportTests: XCTestCase {

    func testFullFrameCoversTheDisplay() {
        let rect = Viewport.full.rect
        XCTAssertEqual(rect.x, 0, accuracy: 0.0001)
        XCTAssertEqual(rect.y, 0, accuracy: 0.0001)
        XCTAssertEqual(rect.w, 1, accuracy: 0.0001)
        XCTAssertEqual(rect.h, 1, accuracy: 0.0001)
    }

    func testZoomIsClamped() {
        XCTAssertEqual(Viewport(centerX: 0.5, centerY: 0.5, zoom: 99).clamped.zoom, Viewport.maxZoom)
        XCTAssertEqual(Viewport(centerX: 0.5, centerY: 0.5, zoom: 0.1).clamped.zoom, 1)
    }

    func testCropStaysInsideTheDisplay() {
        let viewport = Viewport(centerX: 0.02, centerY: 0.98, zoom: 2).clamped
        let rect = viewport.rect
        XCTAssertGreaterThanOrEqual(rect.x, 0)
        XCTAssertGreaterThanOrEqual(rect.y, 0)
        XCTAssertLessThanOrEqual(rect.x + rect.w, 1.0001)
        XCTAssertLessThanOrEqual(rect.y + rect.h, 1.0001)
    }

    func testZoomTwoHalvesTheRegion() {
        let rect = Viewport(centerX: 0.5, centerY: 0.5, zoom: 2).rect
        XCTAssertEqual(rect.w, 0.5, accuracy: 0.0001)
        XCTAssertEqual(rect.h, 0.5, accuracy: 0.0001)
    }
}

final class AudioFrameTests: XCTestCase {

    func testPCMRoundTrip() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let payload = AudioFrame.encode(micros: 1_234, pcm: pcm)
        XCTAssertEqual(payload.count, AudioFrame.headerBytes + pcm.count)
        XCTAssertEqual(AudioFrame.pcm(from: payload), pcm)
    }

    func testHeaderOnlyPayloadYieldsNoSamples() {
        let payload = AudioFrame.encode(micros: 0, pcm: Data())
        XCTAssertEqual(AudioFrame.pcm(from: payload), Data())
    }
}

final class ClipboardTests: XCTestCase {

    func testTextRoundTrip() throws {
        let payload = ClipboardPayload.text("copied from the Mac")
        let decoded = try JSONDecoder().decode(ClipboardPayload.self,
                                               from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.text, "copied from the Mac")
    }

    func testImageRoundTrip() throws {
        let png = Data(repeating: 0x7F, count: 128)
        let payload = try XCTUnwrap(ClipboardPayload.image(png: png))
        let decoded = try JSONDecoder().decode(ClipboardPayload.self,
                                               from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.pngData, png)
    }

    func testOversizedImageIsRefused() {
        let png = Data(repeating: 0, count: ClipboardPayload.maxImageBytes + 1)
        XCTAssertNil(ClipboardPayload.image(png: png))
    }

    func testEmptyTextIsNotProducedByBridge() {
        // The bridge filters empty strings; the payload itself stays simple.
        XCTAssertEqual(ClipboardPayload.text("").text, "")
    }
}

final class PeerEntryTests: XCTestCase {

    func testMacDetection() {
        XCTAssertTrue(PeerEntry(name: "a", ip: "100.1.1.1", os: "macOS", online: true).isMac)
        XCTAssertFalse(PeerEntry(name: "b", ip: "100.1.1.2", os: "linux", online: true).isMac)
    }

    func testListRoundTrip() throws {
        let peers = [
            PeerEntry(name: "kellys-macbook-pro", ip: "100.78.170.16", os: "macOS", online: true),
            PeerEntry(name: "vps", ip: "100.114.237.8", os: "linux", online: false)
        ]
        let data = try JSONEncoder().encode(peers)
        XCTAssertEqual(try JSONDecoder().decode([PeerEntry].self, from: data), peers)
    }
}

final class PingTests: XCTestCase {

    func testRTTIsCarried() throws {
        let ping = PingMessage(sentAtMicros: 123, echo: false, rttMicros: 45_000)
        let decoded = try JSONDecoder().decode(PingMessage.self,
                                               from: JSONEncoder().encode(ping))
        XCTAssertEqual(decoded.rttMicros, 45_000)
        XCTAssertFalse(decoded.echo)
    }
}

final class InputEventTests: XCTestCase {

    private func roundTrip(_ event: InputEvent) throws -> InputEvent {
        let data = try JSONEncoder().encode(event)
        return try JSONDecoder().decode(InputEvent.self, from: data)
    }

    func testEventRoundTrips() throws {
        XCTAssertEqual(try roundTrip(.moveRelative(dx: 1.5, dy: -2.5)),
                       .moveRelative(dx: 1.5, dy: -2.5))
        XCTAssertEqual(try roundTrip(.button(button: 1, down: true)),
                       .button(button: 1, down: true))
        XCTAssertEqual(try roundTrip(.chord(code: 123, flags: EventFlags.control)),
                       .chord(code: 123, flags: EventFlags.control))
        XCTAssertEqual(try roundTrip(.text("hi")), .text("hi"))
        XCTAssertEqual(try roundTrip(.hostAction("missionControl")),
                       .hostAction("missionControl"))
    }

    func testUnknownKindFailsToDecode() {
        let json = Data(#"{"kind":"nonsense"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(InputEvent.self, from: json))
    }
}
