import Foundation
@testable import RawParserKit
import Testing

struct RawFormatRegistryTests {
    @Test
    func `format resolves supported extensions case insensitively`() {
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.arw")) is SonyRawFormat.Type)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.ARW")) is SonyRawFormat.Type)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.nef")) is NikonRawFormat.Type)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.NEF")) is NikonRawFormat.Type)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.dng")) is DNGRawFormat.Type)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.DNG")) is DNGRawFormat.Type)
    }

    @Test
    func `format rejects unsupported extensions`() {
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.jpg")) == nil)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image")) == nil)
    }

    @Test
    func `allExtensions is union of registered raw formats`() {
        #expect(RawFormatRegistry.allExtensions == ["arw", "dng", "nef"])
    }
}

struct SonyRawFormatTests {
    @Test
    func `compressed A7R VI code has a readable label`() {
        #expect(SonyRawFormat.rawFileTypeString(compressionCode: 32766) == "Compressed")
    }

    @Test
    func `lossless compressed code has a readable label`() {
        #expect(SonyRawFormat.rawFileTypeString(compressionCode: 7) == "Lossless Compressed")
    }

    @Test
    func `unknown compression code preserves its numeric value`() {
        #expect(SonyRawFormat.rawFileTypeString(compressionCode: 12345) == "Unknown (12345)")
    }

    @Test
    func `A7R VI uses A7R size thresholds`() {
        let thresholds = SonyRawFormat.sizeClassThresholds(camera: "ILCE-7RM6")

        #expect(thresholds.L == 50)
        #expect(thresholds.M == 22)
    }
}
