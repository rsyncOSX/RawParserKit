//
//  GenericRawThumbnailExtractor.swift
//  RawCull
//
//  Extracts thumbnails for RAW formats with no dedicated vendor extractor,
//  using only ImageIO's built-in RAW decoder — the same decoder CoreImage's
//  `CIRAWFilter` uses. Mirrors the ImageIO half of `DNGThumbnailExtractor`,
//  without a vendor-specific binary fallback.
//

import CoreGraphics
import Foundation
import ImageIO

public enum GenericRawThumbnailExtractor {
    /// Extract a thumbnail using the generic ImageIO framework.
    /// - Parameters:
    ///   - url: The URL of the RAW file.
    ///   - maxDimension: Maximum pixel size for the longest edge of the thumbnail.
    ///   - qualityCost: Interpolation cost (1=low … 5=high).
    /// - Returns: A `CGImage` thumbnail.
    public static func extractThumbnail(
        from url: URL,
        maxDimension: CGFloat,
        qualityCost: Int = 4
    ) async throws -> CGImage {
        try await CancellableImageIOWork.run(qos: .userInitiated) { token in
            try Self.extractSync(
                from: url,
                maxDimension: maxDimension,
                qualityCost: qualityCost,
                cancellationToken: token
            )
        }
    }

    // MARK: - Private

    private nonisolated static func extractSync(
        from url: URL,
        maxDimension: CGFloat,
        qualityCost: Int,
        cancellationToken: ImageIOCancellationToken
    ) throws -> CGImage {
        try cancellationToken.checkCancellation()

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ThumbnailError.invalidSource
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        try cancellationToken.checkCancellation()
        guard let rawThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            throw ThumbnailError.generationFailed
        }

        try cancellationToken.checkCancellation()
        return try rerender(rawThumbnail, qualityCost: qualityCost)
    }

    private nonisolated static func rerender(_ image: CGImage, qualityCost: Int) throws -> CGImage {
        let interpolationQuality: CGInterpolationQuality = switch qualityCost {
        case 1 ... 2: .low
        case 3 ... 4: .medium
        default: .high
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ThumbnailError.contextCreationFailed
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ThumbnailError.contextCreationFailed
        }

        context.interpolationQuality = interpolationQuality
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let result = context.makeImage() else {
            throw ThumbnailError.generationFailed
        }

        return result
    }
}
