//
//  DNGThumbnailExtractor.swift
//  RawCull
//
//  Extracts thumbnails from DNG files using ImageIO with a binary fallback
//  for embedded JPEGs when ImageIO fails to surface them.
//

import CoreGraphics
import Foundation
import ImageIO

public enum DNGThumbnailExtractor {
    /// Extract thumbnail using generic ImageIO framework with binary fallback.
    /// - Parameters:
    ///   - url: The URL of the DNG file.
    ///   - maxDimension: Maximum pixel size for the longest edge of the thumbnail.
    ///   - qualityCost: Interpolation cost (1=low … 5=high).
    /// - Returns: A `CGImage` thumbnail.
    public static func extractDNGThumbnail(
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

        // Try binary fallback first to avoid ImageIO initializing unsupported
        // raw decoders (e.g., for DNGs with compression modes macOS doesn't handle).
        if let embeddedThumbnail = try binaryFallbackThumbnail(
            from: url,
            maxDimension: maxDimension,
            cancellationToken: cancellationToken
        ) {
            try cancellationToken.checkCancellation()
            return try rerender(embeddedThumbnail, qualityCost: qualityCost)
        }

        // Fallback: ask ImageIO for a thumbnail
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

    /// Binary fallback: reads the embedded preview/thumbnail JPEG directly from
    /// the DNG file via TIFF parsing and decodes it as a plain JPEG.
    private nonisolated static func binaryFallbackThumbnail(
        from url: URL,
        maxDimension: CGFloat,
        cancellationToken: ImageIOCancellationToken
    ) throws -> CGImage? {
        try cancellationToken.checkCancellation()

        guard let locations = DNGMakerNoteParser.embeddedJPEGLocations(from: url),
              let loc = locations.preview ?? locations.thumbnail
        else { return nil }

        try cancellationToken.checkCancellation()

        guard let data = DNGMakerNoteParser.readEmbeddedJPEGData(at: loc, from: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]

        try cancellationToken.checkCancellation()
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
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