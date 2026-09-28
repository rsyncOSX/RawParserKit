import CoreImage
import Foundation

/// Shared RAW 9 selection for sensor-data decoding. Embedded JPEG extractors
/// remain available for files that the system's RAW 9 decoder cannot develop.
enum RAWDecoder {
    private nonisolated static let context = CIContext(options: [.useSoftwareRenderer: false])
    private nonisolated static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    nonisolated static func version9(
        in supportedVersions: [CIRAWDecoderVersion]
    ) -> CIRAWDecoderVersion? {
        if supportedVersions.contains(.version9) { return .version9 }
        if supportedVersions.contains(.version9DNG) { return .version9DNG }
        return nil
    }

    /// Keeps the existing system decoder when RAW 9 is unavailable for this file.
    nonisolated static func makeFilter(from url: URL, useRAW9: Bool = false) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        if useRAW9, let version = version9(in: filter.supportedDecoderVersions) {
            filter.decoderVersion = version
        }
        return filter
    }

    /// Returns nil for unsupported files or failed renders so the caller can
    /// continue through its existing sidecar / embedded-JPEG loading path.
    nonisolated static func loadVersion9Image(
        from url: URL,
        maxPixelSize: Int
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let image = await Task.detached(priority: .utility) {
            autoreleasepool {
                guard let filter = CIRAWFilter(imageURL: url),
                      let version = version9(in: filter.supportedDecoderVersions)
                else { return CGImage?.none }

                filter.decoderVersion = version
                let longestEdge = max(filter.nativeSize.width, filter.nativeSize.height)
                guard longestEdge.isFinite, longestEdge > 0 else { return nil }
                filter.scaleFactor = Float(min(CGFloat(max(maxPixelSize, 1)) / longestEdge, 1))

                // CIRAWFilter applies the source EXIF orientation itself.
                guard let output = filter.outputImage else { return nil }
                return render(output, maxPixelSize: maxPixelSize)
            }
        }.value
        return Task.isCancelled ? nil : image
    }

    nonisolated static func render(_ image: CIImage, maxPixelSize: Int) -> CGImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              let sRGB
        else { return nil }

        let scale = min(CGFloat(max(maxPixelSize, 1)) / max(extent.width, extent.height), 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: sRGB)
    }
}
