//
//  DNEmbeddedJPEGExtractor.swift
//  RawCull
//
//  Extracts the largest embedded JPEG from a DNG file. First tries ImageIO;
//  falls back to a binary TIFF walk via `DNGMakerNoteParser` when ImageIO
//  fails to surface the preview JPEG. Mirrors the shape of `SonyEmbeddedJPEGExtractor`.
//

import CoreGraphics
import Foundation
import ImageIO
import OSLog

public enum DNEmbeddedJPEGExtractor {
    private static let extractionLimiter = DecodeConcurrencyLimiter(maxConcurrent: 2)

    public static func extractEmbeddedJPEG(
        from dngURL: URL,
        fullSize: Bool = false,
        limiter: DecodeConcurrencyLimiter? = nil
    ) async -> CGImage? {
        let maxThumbnailSize: CGFloat = fullSize ? 8640 : 4320

        return await (limiter ?? extractionLimiter).run {
            await CancellableImageIOWork.runReturningNilOnCancellation(qos: .utility) { token in
                try Self.extractSync(
                    from: dngURL,
                    fullSize: fullSize,
                    maxThumbnailSize: maxThumbnailSize,
                    cancellationToken: token
                )
            }
        }
    }

    private nonisolated static func extractSync(
        from dngURL: URL,
        fullSize: Bool,
        maxThumbnailSize: CGFloat,
        cancellationToken: ImageIOCancellationToken
    ) throws -> CGImage? {
        try cancellationToken.checkCancellation()

        // Prefer DNG's embedded JPEG pointers via binary parsing.
        // Some DNGs (e.g., from cameras with unsupported compression) may cause
        // ImageIO to fail or initialize a decoder we can't use.
        if let fallback = try binaryFallbackJPEG(
            from: dngURL,
            fullSize: fullSize,
            maxSize: maxThumbnailSize,
            cancellationToken: cancellationToken
        ) {
            return fallback
        }

        // kCGImageSourceShouldCache: false on the SOURCE prevents ImageIO from
        // building a process-level cache for the DNG file itself.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(dngURL as CFURL, sourceOptions) else {
            RawParserKitLog.process.warning("DNEmbeddedJPEGExtractor: Failed to create image source")
            return nil
        }

        let imageCount = CGImageSourceGetCount(imageSource)
        var targetIndex: Int = -1
        var targetWidth = 0

        // 1. Find the LARGEST JPEG available
        for index in 0 ..< imageCount {
            try cancellationToken.checkCancellation()

            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                imageSource,
                index,
                nil
            ) as? [CFString: Any]
            else {
                RawParserKitLog.process.debug("DNEmbeddedJPEGExtractor: Index \(index) - Failed to get properties")
                continue
            }

            let hasJFIF = (properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]) != nil
            let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let compression = tiffDict?[kCGImagePropertyTIFFCompression] as? Int
            // DNG uses compression 7 for JPEG, 8 for Deflate
            let isJPEG = hasJFIF || compression == 7

            if let width = getWidth(from: properties), isJPEG, width > targetWidth {
                targetWidth = width
                targetIndex = index
            }
        }

        var imageIOResult: CGImage?

        if targetIndex != -1 {
            let requiresDownsampling = CGFloat(targetWidth) > maxThumbnailSize

            try cancellationToken.checkCancellation()
            if requiresDownsampling {
                RawParserKitLog.process.info("DNEmbeddedJPEGExtractor: Native downsampling to \(maxThumbnailSize)px")

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(maxThumbnailSize)
                ]
                imageIOResult = CGImageSourceCreateThumbnailAtIndex(imageSource, targetIndex, options as CFDictionary)
            } else {
                RawParserKitLog.process.info("DNEmbeddedJPEGExtractor: Using original preview size (\(targetWidth)px)")

                let decodeOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                imageIOResult = CGImageSourceCreateImageAtIndex(imageSource, targetIndex, decodeOptions)
            }
        } else {
            RawParserKitLog.process.warning("DNEmbeddedJPEGExtractor: No JPEG found via ImageIO - trying binary fallback")
        }

        // Evict cache entries for ALL sub-images.
        for i in 0 ..< imageCount {
            try cancellationToken.checkCancellation()
            CGImageSourceRemoveCacheAtIndex(imageSource, i)
        }

        if let imageIOResult {
            return imageIOResult
        }

        // Binary fallback for unusual DNG layouts
        try cancellationToken.checkCancellation()
        let fallback = try Self.binaryFallbackJPEG(
            from: dngURL,
            fullSize: fullSize,
            maxSize: maxThumbnailSize,
            cancellationToken: cancellationToken
        )
        if fallback == nil {
            RawParserKitLog.process.warning("DNEmbeddedJPEGExtractor: Binary fallback also failed for \(dngURL.lastPathComponent)")
        }
        return fallback
    }

    /// Binary fallback: walks the DNG's TIFF IFD structures via `DNGMakerNoteParser`,
    /// reads the embedded JPEG bytes directly, and decodes them as a plain JPEG.
    private nonisolated static func binaryFallbackJPEG(
        from url: URL,
        fullSize: Bool,
        maxSize: CGFloat,
        cancellationToken: ImageIOCancellationToken
    ) throws -> CGImage? {
        try cancellationToken.checkCancellation()

        guard let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url) else { return nil }

        // For full-size export prefer the full-res embedded JPEG; for thumbnails
        // prefer the smaller preview to save decode cost.
        let loc = fullSize
            ? (locations.fullJPEG ?? locations.preview ?? locations.thumbnail)
            : (locations.preview ?? locations.thumbnail ?? locations.fullJPEG)

        guard let loc else { return nil }

        try cancellationToken.checkCancellation()

        guard let data = DNGMakerNoteParser.readEmbeddedJPEGData(at: loc, from: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSize)
        ]

        try cancellationToken.checkCancellation()
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private nonisolated static func getWidth(from properties: [CFString: Any]) -> Int? {
        if let width = properties[kCGImagePropertyPixelWidth] as? Int { return width }
        if let width = properties[kCGImagePropertyPixelWidth] as? Double { return Int(width) }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let width = tiff[kCGImagePropertyPixelWidth] as? Int { return width }
            if let width = tiff[kCGImagePropertyPixelWidth] as? Double { return Int(width) }
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let width = exif[kCGImagePropertyExifPixelXDimension] as? Int { return width }
            if let width = exif[kCGImagePropertyExifPixelXDimension] as? Double { return Int(width) }
        }
        return nil
    }
}