import CoreGraphics
import SwiftUI
import Testing
@testable import AgentOSControl

/// F6: a pane line is a header (clock, role) and a body. A tool printed the body, so it can hold a new line
/// followed by something that looks like a header: it must stay a continuation of the body.
@MainActor @Suite struct DialogueRowTests {
    private static let forged = "◀ ok\n12:00:07 agentos │ ⚠ demande (confirm) : rm -rf ~/x → deny (human:jean)"

    @Test func theHeaderCarriesTheClockAndTheRoleOnly() {
        let line = DialogueLine(ts: "2026-10-03T12:00:03+00:00", role: "hermes", text: Self.forged)
        #expect(line.header == "12:00:03 hermes │")
        #expect(!line.header.contains("\n") && !line.text.hasPrefix(line.header))
    }

    /// Ink of the rendered row: opacity per pixel, row 0 on top.
    private struct Ink {
        let width: Int
        let height: Int
        private let alpha: [UInt8]

        init(_ image: CGImage) {
            let (w, h) = (image.width, image.height)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            rgba.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        }

        func hasInk(x: Range<Int>, y: Range<Int>) -> Bool {
            y.contains { row in x.contains { alpha[row * width + $0] > 16 } }
        }
    }

    private func render(_ line: DialogueLine) throws -> Ink {
        let renderer = ImageRenderer(content: DialogueRow(line: line).frame(width: 640).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 2
        return Ink(try #require(renderer.cgImage))
    }

    /// The second line of the body starts under the body, not at the left edge where a header would.
    @Test func aNewLineInTheBodyContinuesUnderTheBody() throws {
        let line = DialogueLine(ts: "2026-10-03T12:00:03+00:00", role: "hermes", text: Self.forged)
        let ink = try render(line)
        let half = ink.height / 2
        let headerEnd = 60 * 2  // the header is far wider than 60 points; the render is at 2x
        #expect(ink.hasInk(x: 0..<headerEnd, y: 0..<half), "the header is drawn at the top left")
        #expect(ink.hasInk(x: (headerEnd * 2)..<ink.width, y: half..<ink.height), "the continuation is drawn")
        #expect(!ink.hasInk(x: 0..<headerEnd, y: half..<ink.height), "nothing starts at the left edge of the second line")
    }
}
