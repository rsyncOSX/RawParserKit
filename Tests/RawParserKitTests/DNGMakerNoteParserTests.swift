//
//  DNGMakerNoteParserTests.swift
//  RawParserKitTests
//
//  Tests for DNGMakerNoteParser using synthetic binary TIFF/DNG blobs.
//

import Foundation
@testable import RawParserKit
import Testing

// MARK: - Binary builder helpers

private func le16(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8(v >> 8)]
}

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
}

private func be16(_ v: UInt16) -> [UInt8] {
    [UInt8(v >> 8), UInt8(v & 0xFF)]
}

private func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

private func ifdEntryLE(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> [UInt8] {
    le16(tag) + le16(type) + le32(count) + le32(value)
}

private func ifdEntryBE(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> [UInt8] {
    be16(tag) + be16(type) + be32(count) + be32(value)
}

// MARK: - Test Fixtures

/// Builds a minimal DNG with SubIFD-only layout (no IFD1).
/// Structure:
///   TIFF header (little-endian)
///   IFD0: entries for Preview (0x0111/0x0117) and SubIFDs (0x014A)
///   NextIFD = 0 (no IFD1)
///   SubIFD[0]: JPEGInterchangeFormat/Length pointing to full-res JPEG
private func makeDNGWithSubIFDOnlyLayout(jpegOffset: UInt32, jpegLength: UInt32) throws -> URL {
    let ifd0Offset: UInt32 = 8
    let subIFDOffset = ifd0Offset + 2 + 3 * 12 + 4 // IFD0 with 3 entries + nextIFD

    var bytes: [UInt8] = []

    // TIFF header (little-endian)
    bytes += [0x49, 0x49, 0x2A, 0x00]
    bytes += le32(ifd0Offset)

    // IFD0: 3 entries
    // Entry 0: StripOffsets (0x0111) -> preview offset
    // Entry 1: StripByteCounts (0x0117) -> preview length
    // Entry 2: SubIFDs (0x014A) -> subIFDOffset
    bytes += le16(3)
    bytes += ifdEntryLE(tag: 0x0111, type: 4, count: 1, value: 0x100) // preview at 0x100
    bytes += ifdEntryLE(tag: 0x0117, type: 4, count: 1, value: 50) // preview length
    bytes += ifdEntryLE(tag: 0x014A, type: 4, count: 1, value: subIFDOffset)
    bytes += le32(0) // NextIFD = 0 (no IFD1!)

    // SubIFD: 2 entries for full-res JPEG
    bytes += le16(2)
    bytes += ifdEntryLE(tag: 0x0201, type: 4, count: 1, value: jpegOffset)
    bytes += ifdEntryLE(tag: 0x0202, type: 4, count: 1, value: jpegLength)
    bytes += le32(0) // NextIFD = 0

    // Preview JPEG (smaller) at 0x100
    bytes += [UInt8](repeating: 0, count: 0x100 - bytes.count)
    let previewJPEG: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xD9]
    bytes += previewJPEG

    // Full-res JPEG at jpegOffset
    bytes += [UInt8](repeating: 0, count: Int(jpegOffset) - bytes.count)
    let fullJPEGHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00]
    bytes += fullJPEGHeader
    let payloadLength = Int(jpegLength) - fullJPEGHeader.count - 2 // -2 for FF D9
    bytes += [UInt8](repeating: 0xAA, count: max(0, payloadLength))
    bytes += [0xFF, 0xD9]

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".dng")
    try Data(bytes).write(to: url)
    return url
}

/// Builds a DNG where SubIFD offset is beyond the 512 KB fast-path window.
private func makeDNGWithSubIFDBeyondFastPath() throws -> URL {
    let previewOffset: UInt32 = 0x100
    let previewLength: UInt32 = 100
    let subIFDOffset: UInt32 = 600 * 1024 // Beyond 512 KB
    let jpegOffset = subIFDOffset + 2 + 2 * 12 + 4
    let jpegLength: UInt32 = 5000

    var bytes: [UInt8] = []

    // TIFF header (little-endian)
    bytes += [0x49, 0x49, 0x2A, 0x00]
    bytes += le32(8)

    // IFD0: 3 entries (preview offset, preview length, SubIFDs)
    bytes += le16(3)
    bytes += ifdEntryLE(tag: 0x0111, type: 4, count: 1, value: previewOffset)
    bytes += ifdEntryLE(tag: 0x0117, type: 4, count: 1, value: previewLength)
    bytes += ifdEntryLE(tag: 0x014A, type: 4, count: 1, value: subIFDOffset)
    bytes += le32(0)

    // Pad to preview offset
    bytes += [UInt8](repeating: 0, count: Int(previewOffset) - bytes.count)
    bytes += [UInt8](repeating: 0xBB, count: Int(previewLength))

    // Pad to SubIFD offset
    bytes += [UInt8](repeating: 0, count: Int(subIFDOffset) - bytes.count)

    // SubIFD
    bytes += le16(2)
    bytes += ifdEntryLE(tag: 0x0201, type: 4, count: 1, value: jpegOffset)
    bytes += ifdEntryLE(tag: 0x0202, type: 4, count: 1, value: jpegLength)
    bytes += le32(0)

    // Full-res JPEG
    bytes += [UInt8](repeating: 0, count: Int(jpegOffset) - bytes.count)
    bytes += [0xFF, 0xD8]
    bytes += [UInt8](repeating: 0xCC, count: Int(jpegLength) - 2)
    bytes += [0xFF, 0xD9]

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".dng")
    try Data(bytes).write(to: url)
    return url
}

/// Builds a big-endian DNG with inline SHORT values for JPEG offsets.
private func makeBigEndianDNGWithInlineShort(jpegOffset: UInt16, jpegLength: UInt16) throws -> URL {
    let ifd0Offset: UInt32 = 8
    let subIFDOffset = ifd0Offset + 2 + 1 * 12 + 4
    _ = Int(subIFDOffset + 2 + 2 * 12 + 4) + Int(jpegLength)

    var bytes: [UInt8] = []

    // TIFF header (big-endian: MM)
    bytes += [0x4D, 0x4D, 0x00, 0x2A]
    bytes += be32(ifd0Offset)

    // IFD0: 1 entry -> SubIFDs (0x014A)
    bytes += be16(1)
    bytes += ifdEntryBE(tag: 0x014A, type: 4, count: 1, value: subIFDOffset)
    bytes += be32(0)

    // SubIFD: 2 entries with SHORT type (3) for offsets
    bytes += be16(2)
    // JPEGInterchangeFormat as SHORT (inline value)
    bytes += be16(0x0201)
    bytes += be16(3) // SHORT type
    bytes += be32(1) // count = 1
    bytes += be16(jpegOffset) + [0x00, 0x00] // inline value (padded to 4 bytes)
    // JPEGInterchangeFormatLength as SHORT
    bytes += be16(0x0202)
    bytes += be16(3) // SHORT type
    bytes += be32(1)
    bytes += be16(jpegLength) + [0x00, 0x00]
    bytes += be32(0)

    // JPEG data
    bytes += [UInt8](repeating: 0, count: Int(jpegOffset) - bytes.count)
    bytes += [0xFF, 0xD8]
    bytes += [UInt8](repeating: 0xDD, count: Int(jpegLength) - 2)
    bytes += [0xFF, 0xD9]

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".dng")
    try Data(bytes).write(to: url)
    return url
}

/// Builds a DNG with both byte orders to test byte-order handling
private func makeDNGWithLittleEndian(jpegOffset: UInt32, jpegLength: UInt32) throws -> URL {
    let ifd0Offset: UInt32 = 8
    let subIFDOffset = ifd0Offset + 2 + 1 * 12 + 4

    var bytes: [UInt8] = []

    // TIFF header (little-endian)
    bytes += [0x49, 0x49, 0x2A, 0x00]
    bytes += le32(ifd0Offset)

    // IFD0: 1 entry -> SubIFDs
    bytes += le16(1)
    bytes += ifdEntryLE(tag: 0x014A, type: 4, count: 1, value: subIFDOffset)
    bytes += le32(0)

    // SubIFD: JPEGInterchangeFormat/Length as LONG
    bytes += le16(2)
    bytes += ifdEntryLE(tag: 0x0201, type: 4, count: 1, value: jpegOffset)
    bytes += ifdEntryLE(tag: 0x0202, type: 4, count: 1, value: jpegLength)
    bytes += le32(0)

    // JPEG data
    bytes += [UInt8](repeating: 0, count: Int(jpegOffset) - bytes.count)
    bytes += [0xFF, 0xD8]
    bytes += [UInt8](repeating: 0xEE, count: Int(jpegLength) - 2)
    bytes += [0xFF, 0xD9]

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".dng")
    try Data(bytes).write(to: url)
    return url
}

/// Builds a standards-classified DNG whose IFD0 is the raw image and whose
/// primary rendered preview is stored in a SubIFD.
private func makeDNGWithRawIFD0AndRenderedSubIFDPreview() throws -> URL {
    let ifd0Offset: UInt32 = 8
    let ifd0EntryCount: UInt32 = 5
    let subIFDOffset = ifd0Offset + 2 + ifd0EntryCount * 12 + 4
    let rawOffset: UInt32 = 300
    let rawLength: UInt32 = 20
    let previewOffset: UInt32 = 400
    let previewLength: UInt32 = 50

    var bytes: [UInt8] = []
    bytes += [0x49, 0x49, 0x2A, 0x00]
    bytes += le32(ifd0Offset)

    // IFD0: NewSubFileType=0 identifies the full-resolution raw image.
    bytes += le16(UInt16(ifd0EntryCount))
    bytes += ifdEntryLE(tag: 0x00FE, type: 4, count: 1, value: 0)
    bytes += ifdEntryLE(tag: 0x0103, type: 3, count: 1, value: 7)
    bytes += ifdEntryLE(tag: 0x0111, type: 4, count: 1, value: rawOffset)
    bytes += ifdEntryLE(tag: 0x0117, type: 4, count: 1, value: rawLength)
    bytes += ifdEntryLE(tag: 0x014A, type: 4, count: 1, value: subIFDOffset)
    bytes += le32(0)

    // SubIFD: NewSubFileType=1 identifies the primary rendered preview.
    bytes += le16(4)
    bytes += ifdEntryLE(tag: 0x00FE, type: 4, count: 1, value: 1)
    bytes += ifdEntryLE(tag: 0x0103, type: 3, count: 1, value: 7)
    bytes += ifdEntryLE(tag: 0x0111, type: 4, count: 1, value: previewOffset)
    bytes += ifdEntryLE(tag: 0x0117, type: 4, count: 1, value: previewLength)
    bytes += le32(0)

    bytes += [UInt8](repeating: 0, count: Int(rawOffset) - bytes.count)
    bytes += [UInt8](repeating: 0xAA, count: Int(rawLength))
    bytes += [UInt8](repeating: 0, count: Int(previewOffset) - bytes.count)
    bytes += [0xFF, 0xD8]
    bytes += [UInt8](repeating: 0xBB, count: Int(previewLength) - 4)
    bytes += [0xFF, 0xD9]

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".dng")
    try Data(bytes).write(to: url)
    return url
}

// MARK: - Tests

struct DNGMakerNoteParserTests {

    @Test
    func `Rendered SubIFD preview wins over raw IFD0 strip`() throws {
        let url = try makeDNGWithRawIFD0AndRenderedSubIFDPreview()
        defer { try? FileManager.default.removeItem(at: url) }

        let locations = try #require(DNGMakerNoteParser.embeddedJPEGLocations(from: url))
        let preview = try #require(locations.preview)

        #expect(preview.offset == 400)
        #expect(preview.length == 50)
        #expect(locations.fullJPEG == nil)
    }

    // MARK: P1 Issue 1 - SubIFD-only layout (no IFD1)

    @Test
    func `SubIFD-only layout finds fullJPEG without IFD1`() throws {
        let jpegOffset: UInt32 = 0x200
        let jpegLength: UInt32 = 1000
        let url = try makeDNGWithSubIFDOnlyLayout(jpegOffset: jpegOffset, jpegLength: jpegLength)
        defer { try? FileManager.default.removeItem(at: url) }

        let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url)

        #expect(locations != nil)
        #expect(locations?.preview != nil, "Preview should be found in IFD0")
        #expect(locations?.fullJPEG != nil, "Full JPEG should be found via SubIFD even without IFD1")
        #expect(locations?.fullJPEG?.offset == Int(jpegOffset))
        #expect(locations?.fullJPEG?.length == Int(jpegLength))
    }

    @Test
    func `SubIFD-only layout diagnostics show SubIFD found`() throws {
        let jpegOffset: UInt32 = 0x200
        let jpegLength: UInt32 = 1000
        let url = try makeDNGWithSubIFDOnlyLayout(jpegOffset: jpegOffset, jpegLength: jpegLength)
        defer { try? FileManager.default.removeItem(at: url) }

        let diagnostics = DNGMakerNoteParser.embeddedJPEGLocationsDiagnostics(from: url)

        #expect(diagnostics.value != nil)
        #expect(diagnostics.value?.fullJPEG != nil)
        #expect(diagnostics.trace.contains { $0.contains("SubIFD") && $0.contains("full JPEG found") })
    }

    // MARK: P1 Issue 2 - Retry when fast-path result is incomplete

    @Test
    func `Fast-path retry finds fullJPEG when SubIFD beyond 512 KB window`() throws {
        let url = try makeDNGWithSubIFDBeyondFastPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url)

        #expect(locations != nil)
        #expect(locations?.preview != nil, "Preview should be found in fast path")
        #expect(locations?.fullJPEG != nil, "Full JPEG should be found after full-file retry")
        #expect(locations?.fullJPEG?.length == 5000)
    }

    @Test
    func `Diagnostics show fast-path fallback to full file`() throws {
        let url = try makeDNGWithSubIFDBeyondFastPath()
        defer { try? FileManager.default.removeItem(at: url) }

        let diagnostics = DNGMakerNoteParser.embeddedJPEGLocationsDiagnostics(from: url)

        #expect(diagnostics.value != nil)
        #expect(diagnostics.value?.fullJPEG != nil)
        #expect(diagnostics.trace.contains { $0.contains("slow-path") || $0.contains("full-file") })
    }

    // MARK: P1 Issue 3 - Decode TIFF values according to declared type (big-endian SHORT)

    @Test
    func `Big-endian DNG with inline SHORT offset parsed correctly`() throws {
        let jpegOffset: UInt16 = 0x0200
        let jpegLength: UInt16 = 0x0100
        let url = try makeBigEndianDNGWithInlineShort(jpegOffset: jpegOffset, jpegLength: jpegLength)
        defer { try? FileManager.default.removeItem(at: url) }

        let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url)

        #expect(locations != nil)
        #expect(locations?.fullJPEG != nil, "Full JPEG should be found with correct offset")
        #expect(locations?.fullJPEG?.offset == Int(jpegOffset))
        #expect(locations?.fullJPEG?.length == Int(jpegLength))
    }

    @Test
    func `Little-endian DNG with LONG offsets still works`() throws {
        let jpegOffset: UInt32 = 0x200
        let jpegLength: UInt32 = 1000
        let url = try makeDNGWithLittleEndian(jpegOffset: jpegOffset, jpegLength: jpegLength)
        defer { try? FileManager.default.removeItem(at: url) }

        let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url)

        #expect(locations != nil)
        #expect(locations?.fullJPEG != nil)
        #expect(locations?.fullJPEG?.offset == Int(jpegOffset))
        #expect(locations?.fullJPEG?.length == Int(jpegLength))
    }

    // MARK: Additional edge cases

@Test
    func `Multiple SubIFDs - picks largest JPEG`() throws {
        // Build DNG with two SubIFDs, different JPEG sizes
        let ifd0Offset: UInt32 = 8
        let subIFDArrayOffset = ifd0Offset + 2 + 1 * 12 + 4 // After IFD0 entry + nextIFD
        let subIFD1Offset = subIFDArrayOffset + 8 // Array of 2 LONGs = 8 bytes
        let subIFD1Size: UInt32 = 2 + 2 * 12 + 4
        let subIFD2Offset = subIFD1Offset + subIFD1Size
        let jpeg1Offset = subIFD2Offset + subIFD1Size
        let jpeg1Length: UInt32 = 500
        let jpeg2Offset = jpeg1Offset + jpeg1Length
        let jpeg2Length: UInt32 = 2000

        var bytes: [UInt8] = []
        bytes += [0x49, 0x49, 0x2A, 0x00]
        bytes += le32(ifd0Offset)

        // IFD0: SubIFDs tag with count=2, value = pointer to array
        bytes += le16(1)
        bytes += ifdEntryLE(tag: 0x014A, type: 4, count: 2, value: subIFDArrayOffset)
        bytes += le32(0)

        // Array of 2 SubIFD offsets (LONG each)
        bytes += le32(subIFD1Offset)
        bytes += le32(subIFD2Offset)

        // SubIFD 1
        bytes += le16(2)
        bytes += ifdEntryLE(tag: 0x0201, type: 4, count: 1, value: jpeg1Offset)
        bytes += ifdEntryLE(tag: 0x0202, type: 4, count: 1, value: jpeg1Length)
        bytes += le32(0)

        // SubIFD 2
        bytes += le16(2)
        bytes += ifdEntryLE(tag: 0x0201, type: 4, count: 1, value: jpeg2Offset)
        bytes += ifdEntryLE(tag: 0x0202, type: 4, count: 1, value: jpeg2Length)
        bytes += le32(0)

        // JPEG 1 (smaller)
        bytes += [UInt8](repeating: 0, count: max(0, Int(jpeg1Offset) - bytes.count))
        bytes += [0xFF, 0xD8]
        bytes += [UInt8](repeating: 0x11, count: max(0, Int(jpeg1Length) - 2))
        bytes += [0xFF, 0xD9]

        // JPEG 2 (larger)
        bytes += [UInt8](repeating: 0, count: max(0, Int(jpeg2Offset) - bytes.count))
        bytes += [0xFF, 0xD8]
        bytes += [UInt8](repeating: 0x22, count: max(0, Int(jpeg2Length) - 2))
        bytes += [0xFF, 0xD9]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dng")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url)

        #expect(locations?.fullJPEG?.length == Int(jpeg2Length), "Should pick the larger JPEG")
    }

    @Test
    func `Returns nil for non-TIFF file`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dng")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data([0x00, 0x00, 0x00, 0x00]).write(to: url)

        #expect(DNGMakerNoteParser.embeddedJPEGLocations(from: url) == nil)
    }

    @Test
    func `Returns nil for unknown endian marker`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dng")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data([0x00, 0x00, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]).write(to: url)

        #expect(DNGMakerNoteParser.embeddedJPEGLocations(from: url) == nil)
    }
}
