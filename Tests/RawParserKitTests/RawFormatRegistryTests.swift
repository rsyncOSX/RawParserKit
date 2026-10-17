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
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.cr3")) is GenericRawFormat.Type)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.CR3")) is GenericRawFormat.Type)
    }

    @Test
    func `format rejects unsupported extensions`() {
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.jpg")) == nil)
        #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image")) == nil)
    }

    @Test
    func `allExtensions is union of registered raw formats`() {
        let expected: Set<String> = [
            "arw", "dng", "nef",
            "cr2", "cr3", "crw", "raf", "orf", "rw2", "pef", "ptx", "srw", "x3f",
            "iiq", "3fr", "fff", "dcr", "kdc", "mrw", "erf", "mef", "mos", "nrw",
            "rwl", "bay", "sr2", "srf"
        ]
        #expect(RawFormatRegistry.allExtensions == expected)
    }

    @Test
    func `vendor conformers take priority over the generic fallback`() {
        // Sony, Nikon, and DNG are listed before GenericRawFormat in `all`, so
        // even if an extension were ever claimed by both, the vendor-specific
        // conformer (with MakerNote support) must win.
        #expect(!GenericRawFormat.extensions.contains("arw"))
        #expect(!GenericRawFormat.extensions.contains("nef"))
        #expect(!GenericRawFormat.extensions.contains("dng"))
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

struct GenericRawFormatTests {
    @Test
    func `resolves across the brands with no dedicated conformer`() {
        let extensions = ["cr2", "cr3", "raf", "orf", "rw2", "pef", "srw", "x3f", "iiq"]
        for ext in extensions {
            #expect(RawFormatRegistry.format(for: URL(fileURLWithPath: "/tmp/image.\(ext)")) is GenericRawFormat.Type)
        }
    }

    @Test
    func `focusLocation has no MakerNote parser and returns nil`() {
        #expect(GenericRawFormat.focusLocation(from: URL(fileURLWithPath: "/tmp/image.cr3")) == nil)
    }

    @Test
    func `standard JPEG compression code has a readable label`() {
        #expect(GenericRawFormat.rawFileTypeString(compressionCode: 7) == "JPEG")
    }

    @Test
    func `unknown compression code preserves its numeric value`() {
        #expect(GenericRawFormat.rawFileTypeString(compressionCode: 99999) == "Unknown (99999)")
    }

    @Test
    func `size class uses the generic megapixel fallback regardless of camera`() {
        let thresholds = GenericRawFormat.sizeClassThresholds(camera: "EOS R5")

        #expect(thresholds.L == 25)
        #expect(thresholds.M == 10)
    }
}
