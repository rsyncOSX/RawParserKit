import Foundation
@testable import RawParserKit
import Testing

struct DNGRawFormatTests {
    @Test
    func `extensions include dng`() {
        #expect(DNGRawFormat.extensions == ["dng"])
    }

    @Test
    func `display name is Adobe DNG`() {
        #expect(DNGRawFormat.displayName == "Adobe DNG")
    }

    @Test
    func `compression code 1 is uncompressed`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 1) == "Uncompressed")
    }

    @Test
    func `compression code 7 is JPEG`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 7) == "JPEG")
    }

    @Test
    func `compression code 8 is Deflate`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 8) == "Deflate")
    }

    @Test
    func `compression code 34892 is Lossy DNG`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 34892) == "Lossy DNG")
    }

    @Test
    func `compression code 32773 is PackBits (correct TIFF value)`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 32773) == "PackBits")
    }

    @Test
    func `compression code 52546 is JPEG XL (DNG 1.7)`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 52546) == "JPEG XL")
    }

    @Test
    func `old incorrect PackBits value 34713 is now unknown`() {
        // The old incorrect value should now be treated as unknown
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 34713) == "Unknown (34713)")
    }

    @Test
    func `unknown compression code preserves numeric value`() {
        #expect(DNGRawFormat.rawFileTypeString(compressionCode: 99999) == "Unknown (99999)")
    }

    @Test
    func `size class thresholds for generic camera`() {
        let thresholds = DNGRawFormat.sizeClassThresholds(camera: "Generic Camera")
        #expect(thresholds.L == 25)
        #expect(thresholds.M == 10)
    }

    @Test
    func `size class thresholds for Leica camera`() {
        let thresholds = DNGRawFormat.sizeClassThresholds(camera: "LEICA M11")
        #expect(thresholds.L == 30)
        #expect(thresholds.M == 15)
    }

    @Test
    func `size class thresholds for Pentax 645Z`() {
        let thresholds = DNGRawFormat.sizeClassThresholds(camera: "PENTAX 645Z")
        #expect(thresholds.L == 45)
        #expect(thresholds.M == 20)
    }

    @Test
    func `size class thresholds for Sigma fp`() {
        let thresholds = DNGRawFormat.sizeClassThresholds(camera: "SIGMA FP")
        #expect(thresholds.L == 30)
        #expect(thresholds.M == 15)
    }

    @Test
    func `size class thresholds for DJI`() {
        let thresholds = DNGRawFormat.sizeClassThresholds(camera: "DJI Mavic 3")
        #expect(thresholds.L == 20)
        #expect(thresholds.M == 10)
    }

    @Test
    func `rawSizeClass classifies correctly`() {
        // 30 MP -> L
        #expect(DNGRawFormat.rawSizeClass(width: 6000, height: 5000, camera: "LEICA M11") == "L")
        // 18 MP -> M
        #expect(DNGRawFormat.rawSizeClass(width: 5000, height: 3600, camera: "LEICA M11") == "M")
        // 8 MP -> S
        #expect(DNGRawFormat.rawSizeClass(width: 3000, height: 2600, camera: "LEICA M11") == "S")
    }
}