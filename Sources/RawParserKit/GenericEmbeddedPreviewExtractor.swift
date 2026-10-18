//
//  GenericEmbeddedPreviewExtractor.swift
//  RawCull
//
//  Extracts the largest embedded preview JPEG for RAW formats with no
//  dedicated vendor extractor, using only ImageIO. Mirrors the ImageIO half
//  of `DNEmbeddedJPEGExtractor`'s largest-sub-image search, without a
//  vendor-specific binary fallback.
//

import CoreGraphics
import Foundation
import ImageIO
import OSLog

public enum GenericEmbeddedPreviewExtractor {
    private static let extractionLimiter = DecodeConcurrencyLimiter(maxConcurrent: 2)

    public static func extractEmbeddedPreview(
        from url: URL,
        fullSize: Bool = false,
        limiter: DecodeConcurrencyLimiter? = nil
    ) async -> CGImage? {
        let maxThumbnailSize: CGFloat = fullSize ? 8640 : 4320

        return await (limiter ?? extractionLimiter).run {
            await CancellableImageIOWork.runReturningNilOnCancellation(qos: .utility) { token in
                try Self.extractSync(
                    from: url,
                    maxThumbnailSize: maxThumbnailSize,
                    cancellationToken: token
                )
            }
        }
    }

    // MARK: - Private

    private nonisolated static func extractSync(
        from url: URL,
        maxThumbnailSize: CGFloat,
        cancellationToken: ImageIOCancellationToken
    ) throws -> CGImage? {
        try cancellationToken.checkCancellation()

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            RawParserKitLog.process.warning("GenericEmbeddedPreviewExtractor: Failed to create image source")
            return nil
        }

        let imageCount = CGImageSourceGetCount(imageSource)
        var targetIndex = -1
        var targetWidth = 0

        // Find the largest embedded JPEG sub-image ImageIO exposes.
        for index in 0 ..< imageCount {
            try cancellationToken.checkCancellation()

            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                imageSource,
                index,
                nil
            ) as? [CFString: Any]
            else {
                RawParserKitLog.process.debug("GenericEmbeddedPreviewExtractor: Index \(index) - Failed to get properties")
                continue
            }

            let hasJFIF = (properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any]) != nil
            let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let compression = tiffDict?[kCGImagePropertyTIFFCompression] as? Int
            // Compression 6/7 cover the JPEG codes used across TIFF/EP-derived RAW containers.
            let isJPEG = hasJFIF || compression == 6 || compression == 7

            if let width = getWidth(from: properties), isJPEG, width > targetWidth {
                targetWidth = width
                targetIndex = index
            }
        }

        defer {
            for i in 0 ..< imageCount {
                CGImageSourceRemoveCacheAtIndex(imageSource, i)
            }
        }

        guard targetIndex != -1 else {
            RawParserKitLog.process.warning("GenericEmbeddedPreviewExtractor: No embedded JPEG found via ImageIO")
            return nil
        }

        try cancellationToken.checkCancellation()
        let requiresDownsampling = CGFloat(targetWidth) > maxThumbnailSize
        if requiresDownsampling {
            RawParserKitLog.process.info("GenericEmbeddedPreviewExtractor: Native downsampling to \(maxThumbnailSize)px")

            // RawImageLoader applies source orientation after extraction. Keep
            // this path unoriented, matching the direct decode below.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxThumbnailSize)
            ]
            return CGImageSourceCreateThumbnailAtIndex(imageSource, targetIndex, options as CFDictionary)
        }

        RawParserKitLog.process.info("GenericEmbeddedPreviewExtractor: Using original preview size (\(targetWidth)px)")
        let decodeOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(imageSource, targetIndex, decodeOptions)
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
