//
//  DNGRawFormat.swift
//  RawCull
//
//  `RawFormat` conformer for Adobe DNG. Delegates thumbnail and embedded
//  JPEG extraction to dedicated extractors; focus location uses standard
//  EXIF tags or falls back to camera-specific MakerNote parsing.
//

import CoreGraphics
import Foundation

public enum DNGRawFormat: RawFormat {
    public nonisolated static let extensions: Set<String> = ["dng"]
    public nonisolated static let displayName = "Adobe DNG"

    // MARK: - Thumbnail

    public nonisolated static func extractThumbnail(
        from url: URL,
        maxDimension: CGFloat,
        qualityCost: Int
    ) async throws -> CGImage {
        try await DNGThumbnailExtractor.extractDNGThumbnail(
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
        await DNEmbeddedJPEGExtractor.extractEmbeddedJPEG(from: url, fullSize: fullSize)
    }

    // MARK: - AF focus location

    public nonisolated static func focusLocation(from url: URL) -> String? {
        DNGMakerNoteParser.focusLocation(from: url)
    }

    // MARK: - Compression + size class

    /// DNG TIFF Compression tag values (per TIFF/EP and DNG spec).
    public nonisolated static func rawFileTypeString(compressionCode: Int) -> String {
        switch compressionCode {
        case 1: "Uncompressed"
        case 7: "JPEG" // DNG spec uses 7 for JPEG compression
        case 8: "Deflate" // Adobe Deflate (lossless)
        case 32773: "PackBits" // PackBits (TIFF standard value)
        case 34892: "Lossy DNG" // Lossy DNG compression
        case 52546: "JPEG XL" // DNG 1.7+ JPEG XL
        default: "Unknown (\(compressionCode))"
        }
    }

    /// DNG size-class thresholds. Since DNG is a container used by many cameras,
    /// we use generic megapixel thresholds. Camera-specific overrides could be
    /// added if needed for particular DNG-writing cameras.
    public nonisolated static func sizeClassThresholds(camera: String) -> (L: Double, M: Double) {
        let upper = camera.uppercased()
        // High-resolution DNG cameras (e.g., some medium format, Pentax 645Z, Leica S)
        if upper.contains("645Z") || upper.contains("LEICA S") || upper.contains("HASSELBLAD") {
            return (45, 20) // 50+/25+/12 MP
        }
        // Full-frame mirrorless / DSLR DNG (e.g., Leica M, SL, Q, Sigma fp)
        if upper.contains("LEICA") || upper.contains("SIGMA FP") || upper.contains("PENTAX K-1") {
            return (30, 15) // 35+/18+/9 MP
        }
        // APS-C / Micro Four Thirds DNG
        if upper.contains("RICOH GR") || upper.contains("DJI") || upper.contains("SEA&SEA") {
            return (20, 10) // 24+/12+/6 MP
        }
        return (25, 10) // generic fallback
    }
}