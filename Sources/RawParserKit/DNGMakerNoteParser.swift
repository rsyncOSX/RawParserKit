//
//  DNGMakerNoteParser.swift
//  RawCull
//
//  Parses Adobe DNG raw files to extract AF focus location and embedded
//  JPEG locations natively. DNG is based on TIFF/EP and uses standard EXIF
//  tags. Camera-specific MakerNote data may be present but is not required
//  for basic DNG support.
//
//  Technical background
//  ─────────────────────
//  DNG is TIFF-based (little-endian typical). Key locations:
//    - Embedded preview JPEG: IFD0 tag 0x0111/0x0117 (StripOffsets/ByteCounts)
//                              or 0x0201/0x0202 (JPEGInterchangeFormat/Length)
//    - Embedded thumbnail: IFD1 (next IFD) tag 0x0201/0x0202
//    - Full-res JPEG (if present): SubIFDs via tag 0x014A
//    - Focus location: Standard EXIF tags in MakerNote or ExifIFD
//                      (tag 0xA432 = FocusDistance, etc.)
//    - MakerNote (tag 0x927C) may contain camera-specific AF data
//
//  DNG mandates certain tags. See Adobe DNG Specification 1.7.x.

import Foundation

// MARK: - Embedded JPEG locations

/// Absolute file offsets for JPEGs embedded in a DNG.
/// Mirrors Sony's structure: thumbnail (IFD1), preview (IFD0), fullJPEG (SubIFD).
public struct DNGEmbeddedJPEGLocations: Sendable {
    public struct Location: Sendable {
        public nonisolated let offset: Int
        public nonisolated let length: Int

        public nonisolated init(offset: Int, length: Int) {
            self.offset = offset
            self.length = length
        }
    }

    /// IFD1 tiny thumbnail (~8 KB, ~160 px).
    public nonisolated let thumbnail: Location?
    /// IFD0 preview JPEG (~400 KB, ~1600 px).
    public nonisolated let preview: Location?
    /// SubIFD full-resolution JPEG (if present, ~several MB).
    public nonisolated let fullJPEG: Location?

    public nonisolated init(thumbnail: Location? = nil, preview: Location? = nil, fullJPEG: Location? = nil) {
        self.thumbnail = thumbnail
        self.preview = preview
        self.fullJPEG = fullJPEG
    }
}

// MARK: - Parser

public enum DNGMakerNoteParser {
    /// Returns "width height x y" for the AF focus location encoded in the DNG.
    /// Tries standard EXIF focus tags first, then falls back to camera MakerNote.
    public nonisolated static func focusLocation(from url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        // Fast path: read first 4 MB. Most DNGs store EXIF/MakerNote early.
        guard let data = try? fh.read(upToCount: 4 * 1024 * 1024) else { return nil }
        if let result = DNGTIFFParser(data: data)?.parseFocusLocation() {
            return "\(result.width) \(result.height) \(result.x) \(result.y)"
        }

        // Slow path: full-file read if IFD structures fall beyond 4 MB.
        guard let full = mappedFileData(from: url),
              full.count > data.count,
              let result = DNGTIFFParser(data: full)?.parseFocusLocation()
        else { return nil }
        return "\(result.width) \(result.height) \(result.x) \(result.y)"
    }

    /// Verbose variant for diagnostics.
    public nonisolated static func focusLocationDiagnostics(from url: URL) -> RawParserDiagnostics<String> {
        var trace: [String] = []
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            let failure = "could not open file for reading"
            return .init(value: nil, trace: ["ERROR: \(failure)"], failure: failure)
        }
        defer { try? fh.close() }

        guard let data = try? fh.read(upToCount: 4 * 1024 * 1024) else {
            let failure = "could not read 4 MB fast-path window"
            return .init(value: nil, trace: ["ERROR: \(failure)"], failure: failure)
        }
        trace.append("trace: opened file")
        trace.append("trace: fast-path read bytes=\(data.count)")

        if let parser = DNGTIFFParser(data: data) {
            let parsed = parser.parseFocusLocationDiagnostic()
            trace.append(contentsOf: parsed.trace)
            if let result = parsed.value {
                return .init(
                    value: "\(result.width) \(result.height) \(result.x) \(result.y)",
                    trace: trace,
                    failure: nil
                )
            }
            trace.append("ERROR: fast-path focus parse failed: \(parsed.failure ?? "unknown parser failure")")
        } else {
            trace.append("ERROR: invalid TIFF header in fast-path window")
        }

        guard let full = mappedFileData(from: url), full.count > data.count else {
            let failure = "full-file retry unavailable or not larger than fast-path window"
            trace.append("ERROR: \(failure)")
            return .init(value: nil, trace: trace, failure: failure)
        }
        trace.append("trace: slow-path full-file read bytes=\(full.count)")

        guard let parser = DNGTIFFParser(data: full) else {
            let failure = "invalid TIFF header in full-file retry"
            trace.append("ERROR: \(failure)")
            return .init(value: nil, trace: trace, failure: failure)
        }
        let parsed = parser.parseFocusLocationDiagnostic()
        trace.append(contentsOf: parsed.trace)
        guard let result = parsed.value else {
            let failure = parsed.failure ?? "unknown DNG focus parser failure"
            trace.append("ERROR: slow-path focus parse failed: \(failure)")
            return .init(value: nil, trace: trace, failure: failure)
        }
        return .init(
            value: "\(result.width) \(result.height) \(result.x) \(result.y)",
            trace: trace,
            failure: nil
        )
    }

    /// Parses the TIFF IFD chain and returns absolute file offsets of embedded JPEGs.
    /// Fast path reads first 512 KB; falls back to full-file read if needed.
    public nonisolated static func embeddedJPEGLocations(from url: URL) -> DNGEmbeddedJPEGLocations? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 512 * 1024),
              let parser = DNGTIFFParser(data: data, fileSize: dngFileSize(for: url))
        else { return nil }
        let initial = parser.parseEmbeddedJPEGLocations()

        // If fullJPEG was found, we have what we need. Otherwise, IFD0/SubIFDs may fall beyond the 512 KB window.
        guard initial.fullJPEG == nil else {
            return initial
        }
        guard let full = mappedFileData(from: url),
              full.count > data.count,
              let fullParser = DNGTIFFParser(data: full, fileSize: full.count)
        else { return initial }
        return fullParser.parseEmbeddedJPEGLocations()
    }

    /// Verbose variant for diagnostics.
    public nonisolated static func embeddedJPEGLocationsDiagnostics(from url: URL) -> RawParserDiagnostics<DNGEmbeddedJPEGLocations> {
        var trace: [String] = []
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            let failure = "could not open file for reading"
            return .init(value: nil, trace: ["ERROR: \(failure)"], failure: failure)
        }
        defer { try? fh.close() }

        guard let data = try? fh.read(upToCount: 512 * 1024) else {
            let failure = "could not read 512 KB embedded-JPEG fast-path window"
            return .init(value: nil, trace: ["ERROR: \(failure)"], failure: failure)
        }
        trace.append("trace: opened file")
        trace.append("trace: embedded-JPEG fast-path read bytes=\(data.count)")

        guard let parser = DNGTIFFParser(data: data, fileSize: dngFileSize(for: url)) else {
            let failure = "invalid TIFF header in embedded-JPEG fast-path window"
            trace.append("ERROR: \(failure)")
            return .init(value: nil, trace: trace, failure: failure)
        }

        let initial = parser.parseEmbeddedJPEGLocationsDiagnostic()
        trace.append(contentsOf: initial.trace)
        if let locations = initial.value, locations.fullJPEG != nil {
            return .init(value: locations, trace: trace, failure: nil)
        }

        trace.append("ERROR: fast-path embedded JPEG parse found no full-resolution JPEG")
        guard let full = mappedFileData(from: url), full.count > data.count else {
            let locations = initial.value ?? .init()
            let failure = "full-file retry unavailable; no JPEG offsets found"
            trace.append("ERROR: \(failure)")
            return .init(value: locations, trace: trace, failure: failure)
        }
        trace.append("trace: embedded-JPEG slow-path full-file read bytes=\(full.count)")

        guard let fullParser = DNGTIFFParser(data: full, fileSize: full.count) else {
            let failure = "invalid TIFF header in embedded-JPEG full-file retry"
            trace.append("ERROR: \(failure)")
            return .init(value: initial.value, trace: trace, failure: failure)
        }
        let parsed = fullParser.parseEmbeddedJPEGLocationsDiagnostic()
        trace.append(contentsOf: parsed.trace)
        let locations = parsed.value ?? .init()
        if locations.thumbnail == nil, locations.preview == nil, locations.fullJPEG == nil {
            let failure = parsed.failure ?? "no JPEG offsets found"
            trace.append("ERROR: slow-path embedded JPEG parse failed: \(failure)")
            return .init(value: locations, trace: trace, failure: failure)
        }
        return .init(value: locations, trace: trace, failure: nil)
    }

    /// Reads raw bytes for an embedded JPEG from the file at the given absolute offset.
    public nonisolated static func readEmbeddedJPEGData(
        at location: DNGEmbeddedJPEGLocations.Location,
        from url: URL
    ) -> Data? {
        guard let fileSize = dngFileSize(for: url),
              isValidDNGEmbeddedJPEGLocation(location, fileSize: fileSize)
        else { return nil }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(location.offset))
        return try? fh.read(upToCount: location.length)
    }

    private nonisolated static func dngFileSize(for url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size >= 0
        else { return nil }
        return size
    }

    private nonisolated static func isValidDNGEmbeddedJPEGLocation(
        _ location: DNGEmbeddedJPEGLocations.Location,
        fileSize: Int
    ) -> Bool {
        let maxEmbeddedJPEGLength = 128 * 1024 * 1024
        guard location.offset > 0,
              location.length > 0,
              location.length <= maxEmbeddedJPEGLength,
              location.offset <= fileSize
        else { return false }

        let end = location.offset.addingReportingOverflow(location.length)
        guard !end.overflow else { return false }
        return end.partialValue <= fileSize
    }

    private nonisolated static func mappedFileData(from url: URL) -> Data? {
        guard let fileSize = dngFileSize(for: url), fileSize > 0 else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}

private nonisolated func isValidDNGEmbeddedJPEGLocation(
    _ location: DNGEmbeddedJPEGLocations.Location,
    fileSize: Int
) -> Bool {
    let maxEmbeddedJPEGLength = 128 * 1024 * 1024
    guard location.offset > 0,
          location.length > 0,
          location.length <= maxEmbeddedJPEGLength,
          location.offset <= fileSize
    else { return false }

    let end = location.offset.addingReportingOverflow(location.length)
    guard !end.overflow else { return false }
    return end.partialValue <= fileSize
}

// MARK: - TIFF binary parser for DNG

private struct DNGTIFFParser {
    let data: Data
    let fileSize: Int
    let le: Bool

    nonisolated init?(data: Data, fileSize: Int? = nil) {
        guard data.count >= 8 else { return nil }
        let b0 = data[0], b1 = data[1]
        if b0 == 0x49, b1 == 0x49 { le = true } else if b0 == 0x4D, b1 == 0x4D { le = false } else { return nil }
        self.data = data
        self.fileSize = fileSize ?? data.count
    }

    // MARK: Focus Location

    /// Attempts to parse focus location from standard EXIF tags.
    /// DNG/EXIF doesn't have a single standardized "focus point" tag like Sony/Nikon.
    /// We look for:
    ///   - ExifIFD tag 0xA432 (FocusDistance) — not a point, but distance
    ///   - MakerNote (tag 0x927C) — camera-specific, may contain AF area
    ///   - Some cameras write AF point in proprietary MakerNote tags
    /// Returns nil if no usable focus point data found (common for DNG).
    nonisolated func parseFocusLocation() -> (width: Int, height: Int, x: Int, y: Int)? {
        guard let ifd0 = readU32(at: 4).map(Int.init) else { return nil }

        // Navigate: IFD0 → ExifIFD (tag 0x8769)
        guard let exifIFD = subIFDOffset(in: ifd0, tag: 0x8769) else { return nil }

        // Check MakerNote (tag 0x927C) for camera-specific AF data.
        guard let (mnOffset, mnSize) = tagDataRange(in: exifIFD, tag: 0x927C),
              mnSize >= 8
        else { return nil }

        // Try to parse camera-specific MakerNote for focus point.
        if let result = parseMakerNoteFocusLocation(at: mnOffset, size: mnSize) {
            return result
        }

        return nil
    }

    nonisolated func parseFocusLocationDiagnostic() -> RawParserDiagnostics<(width: Int, height: Int, x: Int, y: Int)> {
        var trace: [String] = []
        guard let ifd0 = readU32(at: 4).map(Int.init) else {
            return .init(value: nil, trace: ["ERROR: missing IFD0 offset at TIFF header byte 4"], failure: "missing IFD0 offset")
        }
        trace.append("trace: TIFF header valid byteOrder=\(le ? "II/little" : "MM/big") ifd0=\(ifd0)")

        guard let exifIFD = subIFDOffset(in: ifd0, tag: 0x8769) else {
            let failure = "missing ExifIFD tag 0x8769 in IFD0"
            return .init(value: nil, trace: trace + ["ERROR: \(failure)"], failure: failure)
        }
        trace.append("trace: ExifIFD tag 0x8769 found offset=\(exifIFD)")

        // Check for FocusDistance (0xA432) in ExifIFD
        if let (fdOffset, fdSize) = tagDataRange(in: exifIFD, tag: 0xA432),
           fdSize >= 8 {
            let num = readU32(at: fdOffset) ?? 0
            let den = readU32(at: fdOffset + 4) ?? 0
            if den != 0 {
                trace.append("trace: FocusDistance tag 0xA432 found = \(num)/\(den) meters")
            }
        } else {
            trace.append("trace: FocusDistance tag 0xA432 not found")
        }

        // Check MakerNote
        guard let (mnOffset, mnSize) = tagDataRange(in: exifIFD, tag: 0x927C) else {
            let failure = "missing MakerNote tag 0x927C in ExifIFD"
            return .init(value: nil, trace: trace + ["ERROR: \(failure)"], failure: failure)
        }
        trace.append("trace: MakerNote tag 0x927C found offset=\(mnOffset) bytes=\(mnSize)")

        if let result = parseMakerNoteFocusLocation(at: mnOffset, size: mnSize) {
            trace.append("trace: parsed focus from MakerNote width=\(result.width) height=\(result.height) x=\(result.x) y=\(result.y)")
            return .init(value: (result.width, result.height, result.x, result.y), trace: trace, failure: nil)
        }

        trace.append("trace: no parseable focus point in MakerNote")
        return .init(value: nil, trace: trace, failure: "no parseable focus point in DNG MakerNote")
    }

    /// Attempts to parse focus location from camera-specific MakerNote data.
    private nonisolated func parseMakerNoteFocusLocation(at offset: Int, size: Int) -> (width: Int, height: Int, x: Int, y: Int)? {
        guard offset + size <= data.count else { return nil }

        // Check for nested TIFF in MakerNote (common pattern)
        if size >= 8 {
            let b0 = data[offset], b1 = data[offset + 1]
            if (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) {
                if let nested = DNGTIFFParser(data: Data(data[offset..<offset+size]), fileSize: size) {
                    return nested.parseFocusLocationFromNestedTIFF()
                }
            }
        }

        return nil
    }

    private nonisolated func parseFocusLocationFromNestedTIFF() -> (width: Int, height: Int, x: Int, y: Int)? {
        guard readU32(at: 4).map(Int.init) != nil else { return nil }

        // Without camera-specific knowledge, we can't reliably parse these.
        // This is a placeholder for future camera-specific parsers.
        return nil
    }

    // MARK: Embedded JPEG locations

    nonisolated func parseEmbeddedJPEGLocations() -> DNGEmbeddedJPEGLocations {
        typealias Loc = DNGEmbeddedJPEGLocations.Location

        guard let ifd0Raw = readU32(at: 4) else { return .init() }
        let ifd0 = Int(ifd0Raw)

        // Prefer DNG's image classification tags over IFD position. IFD0 may be
        // the full-resolution raw image (NewSubFileType == 0), in which case its
        // JPEG-compressed strip is not a rendered preview.
        let ifd0Preview = renderedPreviewJPEG(in: ifd0) ?? unclassifiedJPEG(in: ifd0)

        let subIFDs = subIFDOffsets(in: ifd0, tag: 0x014A)
        let subIFDPreview = subIFDs
            .compactMap { renderedPreviewJPEG(in: $0) }
            .max { $0.length < $1.length }
        let preview = ifd0Preview ?? subIFDPreview

        // Preserve support for older/non-conforming files that do not carry
        // NewSubFileType by treating their SubIFD JPEG as the full-size image.
        let subIFDFullJPEG = subIFDs
            .compactMap { unclassifiedJPEG(in: $0) }
            .max { $0.length < $1.length }

        // Walk IFD chain: IFD0 → IFD1
        guard ifd0 + 2 <= data.count else { return .init(preview: preview, fullJPEG: subIFDFullJPEG) }
        let ifd0Count = Int(readU16(at: ifd0))
        let ifd1Ptr = ifd0 + 2 + ifd0Count * 12
        guard let ifd1Raw = readU32(at: ifd1Ptr), ifd1Raw > 0 else {
            return .init(preview: preview, fullJPEG: subIFDFullJPEG)
        }
        let ifd1 = Int(ifd1Raw)

        // IFD1: tiny thumbnail via JPEGInterchangeFormat (0x0201) + Length (0x0202)
        let thumbnail: Loc? = locateJPEG(in: ifd1, offTag: 0x0201, lenTag: 0x0202)

        // Walk IFD chain: IFD1 → IFD2 (rare in DNG, but possible)
        guard ifd1 + 2 <= data.count else {
            return .init(thumbnail: thumbnail, preview: preview, fullJPEG: subIFDFullJPEG)
        }
        let ifd1Count = Int(readU16(at: ifd1))
        let ifd2Ptr = ifd1 + 2 + ifd1Count * 12
        guard let ifd2Raw = readU32(at: ifd2Ptr), ifd2Raw > 0 else {
            return .init(thumbnail: thumbnail, preview: preview, fullJPEG: subIFDFullJPEG)
        }
        let ifd2 = Int(ifd2Raw)

        // IFD2: full-resolution JPEG (rare)
        let chainFullJPEG: Loc? = locateJPEG(in: ifd2, offTag: 0x0111, lenTag: 0x0117)
            ?? locateJPEG(in: ifd2, offTag: 0x0201, lenTag: 0x0202)
        let fullJPEG = subIFDFullJPEG ?? chainFullJPEG

        return .init(thumbnail: thumbnail, preview: preview, fullJPEG: fullJPEG)
    }

    nonisolated func parseEmbeddedJPEGLocationsDiagnostic() -> RawParserDiagnostics<DNGEmbeddedJPEGLocations> {
        var trace: [String] = []
        guard let ifd0Raw = readU32(at: 4) else {
            return .init(value: nil, trace: ["ERROR: missing IFD0 offset at TIFF header byte 4"], failure: "missing IFD0 offset")
        }
        let ifd0 = Int(ifd0Raw)
        trace.append("trace: TIFF header valid byteOrder=\(le ? "II/little" : "MM/big") ifd0=\(ifd0)")

        let ifd0Type = tagValue(in: ifd0, tag: 0x00FE)
        let ifd0Preview = renderedPreviewJPEG(in: ifd0) ?? unclassifiedJPEG(in: ifd0)
        trace.append("trace: IFD0 NewSubFileType=\(ifd0Type.map(String.init) ?? "missing")")
        trace.append(ifd0Preview == nil ? "trace: IFD0 rendered preview JPEG not found" : "trace: IFD0 rendered preview JPEG found")

        let subIFDs = subIFDOffsets(in: ifd0, tag: 0x014A)
        trace.append("trace: IFD0 SubIFD tag 0x014A offsets count=\(subIFDs.count)")
        let subIFDPreview = subIFDs
            .compactMap { renderedPreviewJPEG(in: $0) }
            .max { $0.length < $1.length }
        let preview = ifd0Preview ?? subIFDPreview
        trace.append(subIFDPreview == nil ? "trace: classified SubIFD preview JPEG not found" : "trace: classified SubIFD preview JPEG found")
        let subIFDFullJPEG = subIFDs
            .compactMap { unclassifiedJPEG(in: $0) }
            .max { $0.length < $1.length }
        trace.append(subIFDFullJPEG == nil ? "trace: unclassified SubIFD full JPEG not found" : "trace: unclassified SubIFD full JPEG found")

        let ifd0Count = Int(readU16(at: ifd0))
        let ifd1Ptr = ifd0 + 2 + ifd0Count * 12
        guard let ifd1Raw = readU32(at: ifd1Ptr), ifd1Raw > 0 else {
            let locations = DNGEmbeddedJPEGLocations(preview: preview, fullJPEG: subIFDFullJPEG)
            let failure = preview == nil && subIFDFullJPEG == nil ? "IFD1 pointer missing and no JPEG offsets found" : nil
            if let failure { trace.append("ERROR: \(failure)") }
            return .init(value: locations, trace: trace, failure: failure)
        }
        let ifd1 = Int(ifd1Raw)
        trace.append("trace: IFD1 pointer found offset=\(ifd1)")

        let thumbnail = locateJPEG(in: ifd1, offTag: 0x0201, lenTag: 0x0202)
        trace.append(thumbnail == nil ? "trace: IFD1 thumbnail JPEG tags not found" : "trace: IFD1 thumbnail JPEG found")

        let ifd1Count = Int(readU16(at: ifd1))
        let ifd2Ptr = ifd1 + 2 + ifd1Count * 12
        guard let ifd2Raw = readU32(at: ifd2Ptr), ifd2Raw > 0 else {
            let locations = DNGEmbeddedJPEGLocations(thumbnail: thumbnail, preview: preview, fullJPEG: subIFDFullJPEG)
            let failure = locations.thumbnail == nil && locations.preview == nil && locations.fullJPEG == nil ? "IFD2 pointer missing and no JPEG offsets found" : nil
            if let failure { trace.append("ERROR: \(failure)") }
            return .init(value: locations, trace: trace, failure: failure)
        }
        let ifd2 = Int(ifd2Raw)
        trace.append("trace: IFD2 pointer found offset=\(ifd2)")

        let chainFullJPEG = locateJPEG(in: ifd2, offTag: 0x0111, lenTag: 0x0117)
            ?? locateJPEG(in: ifd2, offTag: 0x0201, lenTag: 0x0202)
        trace.append(chainFullJPEG == nil ? "trace: IFD2 full JPEG tags not found" : "trace: IFD2 full JPEG found")
        let fullJPEG = subIFDFullJPEG ?? chainFullJPEG

        let locations = DNGEmbeddedJPEGLocations(thumbnail: thumbnail, preview: preview, fullJPEG: fullJPEG)
        let failure = locations.thumbnail == nil && locations.preview == nil && locations.fullJPEG == nil ? "no JPEG offsets found" : nil
        if let failure { trace.append("ERROR: \(failure)") }
        return .init(value: locations, trace: trace, failure: failure)
    }

    // MARK: Binary helpers

    /// Returns a rendered preview only when the DNG metadata classifies the IFD
    /// as reduced-resolution and its compression contains a standalone image.
    private nonisolated func renderedPreviewJPEG(in ifdOffset: Int) -> DNGEmbeddedJPEGLocations.Location? {
        guard let newSubFileType = tagValue(in: ifdOffset, tag: 0x00FE),
              newSubFileType & 1 == 1,
              let compression = tagValue(in: ifdOffset, tag: 0x0103),
              compression == 6 || compression == 7 || compression == 52546
        else { return nil }

        return imageLocation(in: ifdOffset)
    }

    /// Compatibility path for existing DNGs that omit NewSubFileType. Once the
    /// tag is present, its classification is authoritative and raw IFDs are not
    /// exposed as rendered previews.
    private nonisolated func unclassifiedJPEG(in ifdOffset: Int) -> DNGEmbeddedJPEGLocations.Location? {
        guard tagValue(in: ifdOffset, tag: 0x00FE) == nil else { return nil }
        return imageLocation(in: ifdOffset)
    }

    private nonisolated func imageLocation(in ifdOffset: Int) -> DNGEmbeddedJPEGLocations.Location? {
        locateJPEG(in: ifdOffset, offTag: 0x0111, lenTag: 0x0117)
            ?? locateJPEG(in: ifdOffset, offTag: 0x0201, lenTag: 0x0202)
    }

    private nonisolated func tagValue(in ifdOffset: Int, tag: UInt16) -> UInt32? {
        guard let (valueOffset, byteCount) = tagDataRange(in: ifdOffset, tag: tag),
              ifdOffset + 2 <= data.count
        else { return nil }

        let entryCount = Int(readU16(at: ifdOffset))
        for i in 0 ..< entryCount {
            let entry = ifdOffset + 2 + i * 12
            guard entry + 12 <= data.count else { break }
            guard readU16(at: entry) == tag else { continue }
            let type = Int(readU16(at: entry + 2))
            return readValue(at: valueOffset, type: type, byteCount: byteCount)
        }
        return nil
    }

    private nonisolated func locateJPEG(in ifdOffset: Int, offTag: UInt16, lenTag: UInt16) -> DNGEmbeddedJPEGLocations.Location? {
        guard let offset = subIFDOffset(in: ifdOffset, tag: offTag),
              let length = subIFDOffset(in: ifdOffset, tag: lenTag),
              isValidDNGEmbeddedJPEGLocation(.init(offset: offset, length: length), fileSize: fileSize)
        else { return nil }
        return .init(offset: offset, length: length)
    }

    private nonisolated func subIFDOffset(in ifdOffset: Int, tag: UInt16) -> Int? {
        guard let (valLoc, byteCount) = tagDataRange(in: ifdOffset, tag: tag) else { return nil }
        // Read the actual type to decode the value correctly
        guard ifdOffset + 2 <= data.count else { return nil }
        let entryCount = Int(readU16(at: ifdOffset))
        for i in 0 ..< entryCount {
            let e = ifdOffset + 2 + i * 12
            guard e + 12 <= data.count else { break }
            if readU16(at: e) == tag {
                let type = Int(readU16(at: e + 2))
                return readValue(at: valLoc, type: type, byteCount: byteCount).map(Int.init)
            }
        }
        return nil
    }

    private nonisolated func subIFDOffsets(in ifdOffset: Int, tag: UInt16) -> [Int] {
        guard let (valLoc, byteCount) = tagDataRange(in: ifdOffset, tag: tag),
              byteCount >= 2 else { return [] }
        // Read the actual type to decode the values correctly
        guard ifdOffset + 2 <= data.count else { return [] }
        let entryCount = Int(readU16(at: ifdOffset))
        for i in 0 ..< entryCount {
            let e = ifdOffset + 2 + i * 12
            guard e + 12 <= data.count else { break }
            if readU16(at: e) == tag {
                let type = Int(readU16(at: e + 2))
                let sizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]
                let elementSize = type < sizes.count ? sizes[type] : 1
                return stride(from: 0, to: byteCount, by: elementSize).compactMap { offset in
                    readValue(at: valLoc + offset, type: type, byteCount: elementSize).map(Int.init)
                }
            }
        }
        return []
    }

    private nonisolated func readValue(at offset: Int, type: Int, byteCount: Int) -> UInt32? {
        guard offset + byteCount <= data.count else { return nil }
        // TIFF types: 1=BYTE, 2=ASCII, 3=SHORT, 4=LONG, 5=RATIONAL, 7=UNDEFINED, 9=SLONG, etc.
        switch type {
        case 3: // SHORT (2 bytes)
            guard byteCount >= 2 else { return nil }
            return UInt32(readU16(at: offset))
        case 4: // LONG (4 bytes)
            guard byteCount >= 4 else { return nil }
            return readU32(at: offset)
        default:
            // For other types, try reading as U32 if we have enough bytes
            if byteCount >= 4 {
                return readU32(at: offset)
            }
            return nil
        }
    }

    private nonisolated func tagDataRange(in ifdOffset: Int, tag: UInt16) -> (dataOffset: Int, byteCount: Int)? {
        guard ifdOffset + 2 <= data.count else { return nil }
        let entryCount = Int(readU16(at: ifdOffset))
        for i in 0 ..< entryCount {
            let e = ifdOffset + 2 + i * 12
            guard e + 12 <= data.count else { break }
            if readU16(at: e) == tag {
                let type = Int(readU16(at: e + 2))
                let count = Int(readU32(at: e + 4) ?? 0)
                let sizes = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]
                let bytes = count * (type < sizes.count ? sizes[type] : 1)

                if bytes <= 4 { return (e + 8, bytes) }
                guard let ptr = readU32(at: e + 8) else { return nil }
                return (Int(ptr), bytes)
            }
        }
        return nil
    }

    private nonisolated func readU16(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return le ? UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8) :
            (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private nonisolated func readU32(at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return le ? UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24) :
            (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}
