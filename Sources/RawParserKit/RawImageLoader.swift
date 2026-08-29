import AppKit
import ImageIO

public actor RawImageLoader {
    public nonisolated static let shared = RawImageLoader()

    private struct ImageTaskKey: Hashable {
        let url: URL
        let maxPixelSize: Int

        func hash(into hasher: inout Hasher) {
            hasher.combine(url)
            hasher.combine(maxPixelSize)
        }

        static func == (lhs: ImageTaskKey, rhs: ImageTaskKey) -> Bool {
            lhs.url == rhs.url && lhs.maxPixelSize == rhs.maxPixelSize
        }
    }

    private var thumbnailTasks: [ImageTaskKey: Task<NSImage?, Never>] = [:]
    private var extractedJPGTasks: [URL: Task<CGImage?, Never>] = [:]
    private var metadataTasks: [URL: Task<RawImageMetadata?, Never>] = [:]

    /// Bounds how many expensive full-size RAW decodes/demosaics can run at
    /// once. Without this, rapid zoom navigation could otherwise pile up
    /// several uncancelled full-resolution decodes concurrently.
    private let fullSizeDecodeLimiter = DecodeConcurrencyLimiter(maxConcurrent: 2)
    /// Bounds concurrent thumbnail decodes so fast grid scrolling can't spawn
    /// unbounded RAW decode work.
    private let thumbnailDecodeLimiter = DecodeConcurrencyLimiter(maxConcurrent: 6)

    private init() {}

    public func thumbnail(for url: URL, maxPixelSize: Int = 200) async -> NSImage? {
        let boundedTargetSize = max(maxPixelSize, 1)
        let key = ImageTaskKey(url: url, maxPixelSize: boundedTargetSize)

        if let existing = thumbnailTasks[key] {
            return await existing.value
        }

        let limiter = thumbnailDecodeLimiter
        let task = Task<NSImage?, Never>(priority: .utility) {
            guard !Task.isCancelled else { return nil }

            // Bound concurrent decodes: fast grid scrolling can otherwise
            // trigger many simultaneous RAW/embedded-thumbnail decodes.
            let cgImage: CGImage? = await limiter.run {
                guard !Task.isCancelled else { return nil }

                if SupportedFileType.isRenderedImage(url) {
                    return OrientationNormalizedImageLoader.loadThumbnail(
                        from: url,
                        maxPixelSize: boundedTargetSize,
                    )
                }

                if let embeddedThumbnail = OrientationNormalizedImageLoader.loadEmbeddedThumbnail(
                    from: url,
                    maxPixelSize: boundedTargetSize,
                ) {
                    return embeddedThumbnail
                }

                guard let format = RawFormatRegistry.format(for: url),
                      let extracted = try? await format.extractThumbnail(
                          from: url,
                          maxDimension: CGFloat(boundedTargetSize),
                          qualityCost: 4,
                      )
                else { return nil }

                return OrientationNormalizedImageLoader.applyingSourceOrientation(to: extracted, from: url) ?? extracted
            }
            
            guard let cgImage, !Task.isCancelled else { return nil }

            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            return image

        }

        thumbnailTasks[key] = task
        let image = await task.value
        thumbnailTasks[key] = nil
        return image
    }

    public func thumbnailCGImage(for url: URL, maxPixelSize: Int = 200) async -> CGImage? {
        guard let image = await thumbnail(for: url, maxPixelSize: maxPixelSize) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @available(*, deprecated, message: "Use thumbnail(for:maxPixelSize:) instead.")
    public func thumbnail200px(for url: URL, targetSize: Int = 200) async -> NSImage? {
        await thumbnail(for: url, maxPixelSize: targetSize)
    }

    public func previewImage(for rawURL: URL) async -> CGImage? {
        if let existing = extractedJPGTasks[rawURL] {
            return await existing.value
        }

        let limiter = fullSizeDecodeLimiter
        let task = Task<CGImage?, Never>(priority: .userInitiated) {
            await loadExtractedJPGPreview(for: rawURL, limiter: limiter)
        }

        extractedJPGTasks[rawURL] = task
        let image = await task.value
        extractedJPGTasks[rawURL] = nil
        return image
    }

    @available(*, deprecated, message: "Use previewImage(for:) instead.")
    public func extractembeddedJPG(for rawURL: URL) async -> CGImage? {
        await previewImage(for: rawURL)
    }

    private func loadExtractedJPGPreview(for rawURL: URL, limiter: DecodeConcurrencyLimiter) async -> CGImage? {
        let sidecarJPGURL = rawURL
            .deletingPathExtension()
            .appendingPathExtension(SupportedFileType.jpg.rawValue)

        let sidecarImage: CGImage? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: sidecarJPGURL.path) else {
                return nil
            }
            return OrientationNormalizedImageLoader.loadCGImage(from: sidecarJPGURL)
        }.value

        guard !Task.isCancelled else { return nil }
        if let sidecarImage {
            return sidecarImage
        }

       
        guard !Task.isCancelled,
              let format = RawFormatRegistry.format(for: rawURL)
        else { return nil }

        // The expensive step: decode the embedded preview or demosaic the
        // full RAW. Bound via the shared limiter so a burst of navigation
        // requests can't pile up unbounded full-resolution decodes.
        let extracted: CGImage? = await limiter.run {
            guard !Task.isCancelled else { return nil }

            let orientedPreview = await Task.detached(priority: .userInitiated) {
                OrientationNormalizedImageLoader.loadSonyEmbeddedPreview(from: rawURL)
            }.value

            guard !Task.isCancelled else { return nil }

            if let orientedPreview {
                return orientedPreview
            }

            guard let image = await format.extractEmbeddedPreview(from: rawURL, fullSize: false) else {
                return nil
            }
            return OrientationNormalizedImageLoader.applyingSourceOrientation(to: image, from: rawURL) ?? image
        }

        return extracted
        
    }

    public func metadata(for url: URL) async -> RawImageMetadata? {
        if let existing = metadataTasks[url] {
            return await existing.value
        }

        let task = Task<RawImageMetadata?, Never>(priority: .utility) {
            await Self.loadMetadata(from: url)
        }

        metadataTasks[url] = task
        let info = await task.value
        metadataTasks[url] = nil
        return info
    }

    @available(*, deprecated, message: "Use metadata(for:) instead.")
    public func exifInfo(for url: URL) async -> BrowserExifInfo? {
        await metadata(for: url)
    }

    private nonisolated static func loadCGImage(from url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            OrientationNormalizedImageLoader.loadCGImage(from: url)
        }.value
    }

    private nonisolated static func loadMetadata(from url: URL) async -> RawImageMetadata? {
        await Task.detached(priority: .utility) {
            let sidecarURL = url.deletingPathExtension().appendingPathExtension("jpg")
            let properties = imageProperties(from: url) ?? imageProperties(from: sidecarURL)
            let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let format = RawFormatRegistry.format(for: url)

            let make = stringValue(tiff?[kCGImagePropertyTIFFMake])
            let model = stringValue(tiff?[kCGImagePropertyTIFFModel])
            let camera = joined([make, model])

            let exposureTimeSeconds = positiveNumberValue(exif?[kCGImagePropertyExifExposureTime])
            let fNumber = positiveNumberValue(exif?[kCGImagePropertyExifFNumber])
            let focalLengthMM = positiveNumberValue(exif?[kCGImagePropertyExifFocalLength])
            let isoValue = isoNumber(exif?[kCGImagePropertyExifISOSpeedRatings])
            let exposureCompensationEV = finiteNumberValue(exif?[kCGImagePropertyExifExposureBiasValue])
            let pixelWidth = intValue(properties?[kCGImagePropertyPixelWidth]) ?? intValue(exif?[kCGImagePropertyExifPixelXDimension])
            let pixelHeight = intValue(properties?[kCGImagePropertyPixelHeight]) ?? intValue(exif?[kCGImagePropertyExifPixelYDimension])
            let compression = intValue(tiff?[kCGImagePropertyTIFFCompression])
            let cameraModel = model ?? camera ?? ""
            let rawSizeClass: String? = if let pixelWidth, let pixelHeight, let format {
                format.rawSizeClass(width: pixelWidth, height: pixelHeight, camera: cameraModel)
            } else {
                nil
            }

            let lens = stringValue(exif?[kCGImagePropertyExifLensModel])
            let exposure = shutterDescription(exposureTimeSeconds)
            let aperture = apertureDescription(fNumber)
            let focalLength = focalLengthDescription(focalLengthMM)
            let iso = isoDescription(exif?[kCGImagePropertyExifISOSpeedRatings])
            let dateTimeOriginal = stringValue(exif?[kCGImagePropertyExifDateTimeOriginal])
            let captureTimeZoneOffsetSeconds = captureTimeZoneOffsetSeconds(
                from: stringValue(exif?[kCGImagePropertyExifOffsetTimeOriginal]),
            )
            let captureDate = captureDate(
                from: dateTimeOriginal,
                subsecond: stringValue(exif?[kCGImagePropertyExifSubsecTimeOriginal]),
                offset: captureTimeZoneOffsetSeconds,
            )
            let capturedAt = capturedAtDescription(
                dateTimeOriginal ?? stringValue(tiff?[kCGImagePropertyTIFFDateTime]),
            )
            let dimensions = properties.flatMap { dimensionsDescription(properties: $0, exif: exif) }
            let loadedFocusPoint = makerNoteFocusPoint(from: url) ?? properties.flatMap {
                focusPoint(
                    from: exif?[kCGImagePropertyExifSubjectArea],
                    properties: $0,
                    exif: exif,
                )
            }

            let info = RawImageMetadata(
                camera: camera,
                lens: lens,
                exposure: exposure,
                exposureTimeSeconds: exposureTimeSeconds,
                aperture: aperture,
                apertureValue: fNumber,
                focalLength: focalLength,
                focalLengthMM: focalLengthMM,
                iso: iso,
                isoValue: isoValue,
                exposureCompensationEV: exposureCompensationEV,
                capturedAt: capturedAt,
                captureDate: captureDate,
                captureTimeZoneOffsetSeconds: captureTimeZoneOffsetSeconds,
                dimensions: dimensions,
                focusPoint: loadedFocusPoint,
                rawFileType: compression.flatMap { format?.rawFileTypeString(compressionCode: $0) },
                rawSizeClass: rawSizeClass,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
            )
            return info.isEmpty ? nil : info
        }.value
    }

    private nonisolated static func imageProperties(from url: URL) -> [CFString: Any]? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties
    }

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed

        case let value as NSNumber:
            return value.stringValue

        default:
            return nil
        }
    }

    private nonisolated static func numberValue(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            value.doubleValue

        case let value as String:
            Double(value)

        default:
            nil
        }
    }

    private nonisolated static func finiteNumberValue(_ value: Any?) -> Double? {
        guard let value = numberValue(value), value.isFinite else { return nil }
        return value
    }

    private nonisolated static func positiveNumberValue(_ value: Any?) -> Double? {
        guard let value = finiteNumberValue(value), value > 0 else { return nil }
        return value
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as NSNumber:
            value.intValue

        case let value as String:
            Int(value)

        default:
            nil
        }
    }

    private nonisolated static func isoNumber(_ value: Any?) -> Int? {
        if let values = value as? [Any],
           let iso = values.compactMap({ intValue($0) }).first {
            return iso
        }
        return intValue(value)
    }

    private nonisolated static func joined(_ values: [String?]) -> String? {
        var parts: [String] = []
        for value in values.compactMap({ $0 }) where !parts.contains(value) {
            parts.append(value)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private nonisolated static func shutterDescription(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 1 {
            return "\(trimmed(seconds)) s"
        }
        return "1/\(Int(round(1 / seconds))) s"
    }

    private nonisolated static func apertureDescription(_ aperture: Double?) -> String? {
        guard let aperture, aperture > 0 else { return nil }
        return "f/\(trimmed(aperture))"
    }

    private nonisolated static func focalLengthDescription(_ focalLength: Double?) -> String? {
        guard let focalLength, focalLength > 0 else { return nil }
        return "\(trimmed(focalLength)) mm"
    }

    private nonisolated static func isoDescription(_ value: Any?) -> String? {
        if let values = value as? [Any],
           let iso = values.compactMap({ intValue($0) }).first {
            return "\(iso)"
        }
        if let iso = intValue(value) {
            return "\(iso)"
        }
        return nil
    }

    private nonisolated static func capturedAtDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")

        guard let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    nonisolated static func captureDate(
        from dateTimeOriginal: String?,
        subsecond: String?,
        offset: String?,
        defaultTimeZone: TimeZone = .current,
    ) -> Date? {
        captureDate(
            from: dateTimeOriginal,
            subsecond: subsecond,
            offset: captureTimeZoneOffsetSeconds(from: offset),
            defaultTimeZone: defaultTimeZone,
        )
    }

    private nonisolated static func captureDate(
        from dateTimeOriginal: String?,
        subsecond: String?,
        offset: Int?,
        defaultTimeZone: TimeZone = .current,
    ) -> Date? {
        guard let dateTimeOriginal = stringValue(dateTimeOriginal) else { return nil }

        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = offset.flatMap(TimeZone.init(secondsFromGMT:)) ?? defaultTimeZone
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.isLenient = false

        guard var date = parser.date(from: dateTimeOriginal) else { return nil }
        guard let subsecond = stringValue(subsecond) else { return date }

        let digits = subsecond
            .drop(while: { $0 == "." })
            .prefix(while: \Character.isNumber)
        if !digits.isEmpty,
           let fraction = TimeInterval("0.\(digits)") {
            date.addTimeInterval(fraction)
        }
        return date
    }

    nonisolated static func captureTimeZoneOffsetSeconds(from value: String?) -> Int? {
        guard var value = stringValue(value) else { return nil }
        if value == "Z" { return 0 }

        let sign: Int
        switch value.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        value.removeFirst()

        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        let hours: Int?
        let minutes: Int?
        if components.count == 2 {
            hours = Int(components[0])
            minutes = Int(components[1])
        } else if value.count == 4 {
            hours = Int(value.prefix(2))
            minutes = Int(value.suffix(2))
        } else {
            return nil
        }

        guard let hours, let minutes, hours <= 23, minutes <= 59 else { return nil }
        return sign * ((hours * 60 + minutes) * 60)
    }

    private nonisolated static func dimensionsDescription(properties: [CFString: Any], exif: [CFString: Any]?) -> String? {
        let width = intValue(properties[kCGImagePropertyPixelWidth]) ?? intValue(exif?[kCGImagePropertyExifPixelXDimension])
        let height = intValue(properties[kCGImagePropertyPixelHeight]) ?? intValue(exif?[kCGImagePropertyExifPixelYDimension])
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) x \(height)"
    }

    private nonisolated static func makerNoteFocusPoint(from url: URL) -> RawFocusPoint? {
        guard let focusLocation = RawFormatRegistry.format(for: url)?.focusLocation(from: url) else { return nil }
        return RawFocusPoint(focusLocation: focusLocation)
    }

    private nonisolated static func focusPoint(
        from value: Any?,
        properties: [CFString: Any],
        exif: [CFString: Any]?,
    ) -> RawFocusPoint? {
        let values = numericArray(value)
        guard values.count >= 2 else { return nil }

        let width = numberValue(properties[kCGImagePropertyPixelWidth]) ?? numberValue(exif?[kCGImagePropertyExifPixelXDimension])
        let height = numberValue(properties[kCGImagePropertyPixelHeight]) ?? numberValue(exif?[kCGImagePropertyExifPixelYDimension])
        guard let width, let height, width > 0, height > 0 else { return nil }

        let normalizedX = values[0] / width
        let normalizedY = values[1] / height
        guard (0 ... 1).contains(normalizedX), (0 ... 1).contains(normalizedY) else { return nil }
        return RawFocusPoint(normalizedX: normalizedX, normalizedY: normalizedY)
    }

    private nonisolated static func numericArray(_ value: Any?) -> [Double] {
        switch value {
        case let values as [Any]:
            values.compactMap(numberValue)

        case let values as NSArray:
            values.compactMap(numberValue)

        default:
            []
        }
    }

    private nonisolated static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    private nonisolated static func supportedFileCount(in folderURL: URL) -> Int {
        let supported = RawFormatRegistry.allExtensions.union(SupportedFileType.renderedImageExtensions)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else { return 0 }

        let supportedFiles = children.filter { url in
            guard supported.contains(url.pathExtension.lowercased()) else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        let renderedImageCount = supportedFiles.count(where: SupportedFileType.isRenderedImage)
        return renderedImageCount > 0 ? renderedImageCount : supportedFiles.count
    }
}
