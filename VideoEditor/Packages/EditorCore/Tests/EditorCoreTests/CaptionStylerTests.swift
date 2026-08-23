import Testing
import CoreGraphics
@testable import EditorCore

@Suite("Caption Styler Tests")
struct CaptionStylerTests {
    @Test("Karaoke captions fit within horizontal safe bounds")
    func karaokeCaptionFitsSafeBounds() throws {
        let size = CGSize(width: 1080, height: 1920)
        let image = try #require(CaptionStyler.renderCaption(
            text: "extraordinary differentiated products overflowing captions",
            activeWordIndex: 2,
            style: .karaoke,
            size: size,
            fontSize: 72,
            placement: .bottom
        ))

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        try #require(context).draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var maxX = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                if alpha > 8 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }

        let safeMargin = Int(Double(width) * 0.075)
        #expect(minX >= safeMargin - 2)
        #expect(maxX <= width - safeMargin + 2)
    }
}
