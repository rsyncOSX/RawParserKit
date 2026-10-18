import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RawParserKit

struct GenericEmbeddedPreviewExtractorTests {
    @Test("Generic portrait previews are oriented once by the loader", arguments: [
        (4000, 800, 4000),
        (5000, 864, 4320)
    ])
    func portraitPreview(sourceWidth: Int, expectedWidth: Int, expectedHeight: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // ImageIO detects the JPEG payload independently of the extension. Using
        // CR2 routes this synthetic preview through GenericRawFormat without
        // needing a camera RAW fixture or a platform-specific RAW decoder.
        let url = directory.appendingPathComponent("portrait.cr2")
        let context = try #require(CGContext(
            data: nil,
            width: sourceWidth,
            height: sourceWidth / 5,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let preview = try #require(await RawImageLoader.shared.previewImage(for: url))
        #expect(preview.width == expectedWidth)
        #expect(preview.height == expectedHeight)
    }
}
