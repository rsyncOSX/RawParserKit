//
//  SonyRAWJPEGCreator.swift
//  RawParserKit
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum SonyJPEGCreationError: Error, Equatable, LocalizedError, Sendable {
    case invalidQuality(Double)
    case unsupportedOrInvalidRAW
    case encodingFailed

    public nonisolated var errorDescription: String? {
        switch self {
        case let .invalidQuality(quality):
            "JPEG quality must be between 0.0 and 1.0. Received \(quality)."
        case .unsupportedOrInvalidRAW:
            "The Sony RAW file is invalid or is not supported by the installed macOS RAW decoder."
        case .encodingFailed:
            "Core Image could not encode the developed RAW image as JPEG data."
        }
    }
}

enum SonyRAWJPEGCreator {
    private nonisolated static let context = CIContext(options: [.useSoftwareRenderer: false])
    private nonisolated static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    nonisolated static func createFullSizeJPEG(
        from url: URL,
        quality: Double,
        useRAW9: Bool = false
    ) async throws -> Data {
        guard quality.isFinite, (0.0 ... 1.0).contains(quality) else {
            throw SonyJPEGCreationError.invalidQuality(quality)
        }

        return try await CancellableImageIOWork.run(qos: .utility) { token in
            try token.checkCancellation()

            guard let rawFilter = RAWDecoder.makeFilter(from: url, useRAW9: useRAW9),
                  let image = rawFilter.outputImage,
                  !image.extent.isEmpty,
                  !image.extent.isInfinite,
                  !image.extent.isNull
            else {
                throw SonyJPEGCreationError.unsupportedOrInvalidRAW
            }

            try token.checkCancellation()
            guard canRender(image) else {
                throw SonyJPEGCreationError.unsupportedOrInvalidRAW
            }

            try token.checkCancellation()
            let data = try encodeJPEG(from: image, quality: quality)
            try token.checkCancellation()
            return data
        }
    }

    private nonisolated static func canRender(_ image: CIImage) -> Bool {
        guard let sRGBColorSpace else { return false }

        let extent = image.extent.integral
        let probeRect = CGRect(x: extent.minX, y: extent.minY, width: 1, height: 1)
        return context.createCGImage(
            image,
            from: probeRect,
            format: .RGBA8,
            colorSpace: sRGBColorSpace
        ) != nil
    }

    nonisolated static func encodeJPEG(from image: CIImage, quality: Double) throws -> Data {
        guard let sRGBColorSpace else {
            throw SonyJPEGCreationError.encodingFailed
        }

        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(
                rawValue: kCGImageDestinationLossyCompressionQuality as String
            ): quality
        ]

        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: sRGBColorSpace,
            options: options
        ) else {
            throw SonyJPEGCreationError.encodingFailed
        }

        return data
    }
}
