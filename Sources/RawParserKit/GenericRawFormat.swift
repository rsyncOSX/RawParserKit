//
//  GenericRawFormat.swift
//  RawCull
//
//  `RawFormat` conformer for RAW formats macOS's built-in Camera RAW decoder
//  (the same decoder ImageIO and CoreImage share) can open, but which don't
//  yet have a dedicated vendor conformer with MakerNote-based AF-point
//  extraction or a binary embedded-JPEG fallback. Thumbnail and preview
//  extraction rely entirely on ImageIO, which already demosaics/extracts
//  previews for these formats wherever the OS ships a decoder for them.
//
//  Give a brand its own conformer (see `SonyRawFormat`, `NikonRawFormat`,
//  `DNGRawFormat`) and drop its extensions from this list once it needs
//  MakerNote focus points, per-body size-class thresholds, or a binary
//  fallback for embedded previews.
//

import CoreGraphics
import Foundation

public enum GenericRawFormat: RawFormat {
    /// Extensions for RAW formats with no dedicated vendor conformer, but
    /// which macOS's built-in RAW decoder is known to open. Not exhaustive
    /// of every RAW extension that has ever existed — only ones ImageIO and
    /// CoreImage can decode via the system's RAW camera support.
    public nonisolated static let extensions: Set<String> = [
        "cr2", "cr3", "crw", // Canon
        "raf", // Fujifilm
        "orf", // Olympus / OM System
        "rw2", // Panasonic
        "pef", "ptx", // Pentax / Ricoh
        "srw", // Samsung
        "x3f", // Sigma
        "iiq", // Phase One
        "3fr", "fff", // Hasselblad
        "dcr", "kdc", // Kodak
        "mrw", // Minolta / Konica Minolta
        "erf", // Epson
        "mef", // Mamiya
        "mos", // Leaf
        "nrw", // Nikon compact-camera RAW (distinct container from NEF)
        "rwl", // Leica
        "bay", // Casio
        "sr2", "srf" // Sony (legacy models that predate ARW)
    ]

    public nonisolated static let displayName = "RAW"

    // MARK: - Thumbnail

    public nonisolated static func extractThumbnail(
        from url: URL,
        maxDimension: CGFloat,
        qualityCost: Int
    ) async throws -> CGImage {
        try await GenericRawThumbnailExtractor.extractThumbnail(
            from: url,
            maxDimension: maxDimension,
            qualityCost: qualityCost
        )
    }

    @available(*, deprecated, message: "Use extractEmbeddedPreview(from:fullSize:) instead.")
    public nonisolated static func extractFullJPEG(from url: URL, fullSize: Bool) async -> CGImage? {
        await extractEmbeddedPreview(from: url, fullSize: fullSize)
    }

    public nonisolated static func extractEmbeddedPreview(from url: URL, fullSize: Bool) async -> CGImage? {
        await GenericEmbeddedPreviewExtractor.extractEmbeddedPreview(from: url, fullSize: fullSize)
    }

    // MARK: - AF focus location

    /// No vendor MakerNote parser is registered for these formats.
    /// `RawImageLoader` falls back to standard EXIF `SubjectArea` parsing
    /// whenever this returns nil.
    public nonisolated static func focusLocation(from url: URL) -> String? { nil }

    // MARK: - Compression + size class

    /// TIFF Compression tag values vary by vendor. Without a per-brand
    /// table, only the handful of values standardized across TIFF/EP- and
    /// DNG-derived RAW containers are labeled.
    public nonisolated static func rawFileTypeString(compressionCode: Int) -> String {
        switch compressionCode {
        case 1: "Uncompressed"
        case 6: "JPEG"
        case 7: "JPEG" // TIFF/EP + DNG spec value
        case 8: "Deflate"
        case 32773: "PackBits"
        default: "Unknown (\(compressionCode))"
        }
    }

    /// No per-body megapixel thresholds are known for this long tail of
    /// cameras; use the same generic fallback `DNGRawFormat` uses for
    /// unrecognized bodies.
    public nonisolated static func sizeClassThresholds(camera: String) -> (L: Double, M: Double) {
        (25, 10)
    }
}
