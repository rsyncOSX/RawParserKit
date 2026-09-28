//
//  SonyRawFormat.swift
//  RawCull
//
//  Thin `RawFormat` conformer that forwards to the existing Sony enums
//  (`SonyThumbnailExtractor`, `JPGSonyARWExtractor`, `SonyMakerNoteParser`).
//  Sony-specific compression codes and A-series size-class thresholds live
//  here so that per-vendor knowledge sits with its format.
//

import CoreGraphics
import Foundation

public enum SonyRawFormat: RawFormat {
    public nonisolated static let extensions: Set<String> = ["arw"]
    public nonisolated static let displayName = "Sony ARW"

    public nonisolated static func extractThumbnail(
        from url: URL,
        maxDimension: CGFloat,
        qualityCost: Int
    ) async throws -> CGImage {
        try await SonyThumbnailExtractor.extractSonyThumbnail(
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
        await SonyEmbeddedJPEGExtractor.extractEmbeddedJPEG(from: url, fullSize: fullSize)
    }

    /// Develops the Sony ARW sensor data at its full resolution and encodes it as sRGB JPEG data.
    ///
    /// This does not use the camera's embedded JPEG. Availability depends on the Sony camera and
    /// RAW compression modes supported by the RAW decoder installed with macOS.
    /// Pass `useRAW9: true` to prefer RAW 9 when the file supports it.
    public nonisolated static func createFullSizeJPEG(
        from url: URL,
        quality: Double = 1.0,
        useRAW9: Bool = false
    ) async throws -> Data {
        try await SonyRAWJPEGCreator.createFullSizeJPEG(from: url, quality: quality, useRAW9: useRAW9)
    }

    public nonisolated static func focusLocation(from url: URL) -> String? {
        SonyMakerNoteParser.focusLocation(from: url)
    }

    /// TIFF Compression tag values used by Sony RAW. Newer bodies (A1, A7R V/VI…)
    /// write 6/7 or 32766; older bodies (A7R III and earlier) write 32767/32770.
    public nonisolated static func rawFileTypeString(compressionCode: Int) -> String {
        switch compressionCode {
        case 1: "Uncompressed"
        case 6: "Compressed"
        case 7: "Lossless Compressed"
        case 32766: "Compressed"
        case 32767: "Compressed"
        case 32770: "Lossless Compressed"
        default: "Unknown (\(compressionCode))"
        }
    }

    /// Per-body MP thresholds for L / M / S classification.
    public nonisolated static func sizeClassThresholds(camera: String) -> (L: Double, M: Double) {
        let upper = camera.uppercased()
        if upper.contains("ILCE-7RM") { return (50, 22) } // A7R IV/V/VI: 61/26/15 MP
        if upper.contains("ILCE-1") { return (40, 18) } // A1/A1 II: 50/21/12 MP
        if upper.contains("ILCE-9") { return (20, 10) } // A9 III: 24/12/6 MP
        if upper.contains("ILCE-7") { return (28, 14) } // A7M5: 33/17/9 MP
        return (25, 10) // generic fallback
    }
}
