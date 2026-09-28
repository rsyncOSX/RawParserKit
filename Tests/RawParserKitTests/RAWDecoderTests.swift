import CoreImage
import Foundation
@testable import RawParserKit
import Testing

struct RAWDecoderTests {
    @Test(arguments: [
        ([CIRAWDecoderVersion.version8, .version9], CIRAWDecoderVersion.version9),
        ([CIRAWDecoderVersion.version8DNG, .version9DNG], CIRAWDecoderVersion.version9DNG),
    ])
    func `selects supported RAW 9 variant`(
        versions: [CIRAWDecoderVersion], expected: CIRAWDecoderVersion
    ) {
        #expect(RAWDecoder.version9(in: versions) == expected)
    }

    @Test(arguments: [[], [CIRAWDecoderVersion.version8], [.version8DNG]])
    func `older decoder support leaves existing loading available`(versions: [CIRAWDecoderVersion]) {
        #expect(RAWDecoder.version9(in: versions) == nil)
    }

    @Test
    func `render scales to requested size without upscaling`() throws {
        let image = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        let thumbnail = try #require(RAWDecoder.render(image, maxPixelSize: 48))
        #expect(thumbnail.width == 48)
        #expect(thumbnail.height == 32)
        let preview = try #require(RAWDecoder.render(image, maxPixelSize: 4320))
        #expect(preview.width == 96)
        #expect(preview.height == 64)
    }

    @Test
    func `invalid output extent is rejected`() {
        #expect(RAWDecoder.render(CIImage(color: .white), maxPixelSize: 48) == nil)
        #expect(RAWDecoder.render(CIImage.empty(), maxPixelSize: 48) == nil)
    }

    @Test(arguments: [false, true])
    func `unsupported RAW falls back to sidecar preview`(useRAW9: Bool) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsupported-\(UUID().uuidString).arw")
        let sidecar = url.deletingPathExtension().appendingPathExtension("jpg")
        try Data("not RAW data".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sidecar)
        }
        let image = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: 96, height: 64))
        try SonyRAWJPEGCreator.encodeJPEG(from: image, quality: 1).write(to: sidecar)

        #expect(await RAWDecoder.loadVersion9Image(from: url, maxPixelSize: 48) == nil)
        let preview = try #require(await RawImageLoader.shared.previewImage(for: url, useRAW9: useRAW9))
        #expect(preview.width == 96)
        #expect(preview.height == 64)
    }
}
