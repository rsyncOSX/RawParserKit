# RawParserKit

RawParserKit is a Swift package for RAW-file parser and preview extraction logic used by RawCull. It keeps camera-vendor binary knowledge in one focused module: MakerNote focus-location parsing, embedded JPEG location discovery, thumbnail extraction, full-preview JPEG extraction, and cancellation-safe ImageIO work.

The package is intentionally independent of RawCull view models, SwiftUI views, persistence, and cache layers. It is suitable for unit testing with synthetic RAW-like TIFF data and for reuse from a macOS app target.

## Supported Formats

- Sony `.arw`
- Nikon `.nef`
- Adobe Digital Negative `.dng`
- Rendered-image helpers for `.jpg`, `.jpeg`, `.png`, `.tif`, and `.tiff`

## Requirements

- Swift 6.2
- macOS 26 or newer
- Apple platforms with Foundation, AppKit, CoreGraphics, ImageIO, CoreImage, and OSLog

## Package APIs

### Format Dispatch

Use these APIs when you want vendor-neutral RAW handling.

- `RawFormat`: protocol implemented by each vendor format. It exposes `extensions`, `displayName`, `extractThumbnail(from:maxDimension:qualityCost:)`, `extractEmbeddedPreview(from:fullSize:)`, `focusLocation(from:)`, `rawFileTypeString(compressionCode:)`, `sizeClassThresholds(camera:)`, and `rawSizeClass(width:height:camera:)`.
- `RawFormatRegistry.all`: registered format types.
- `RawFormatRegistry.allExtensions`: union of supported RAW extensions.
- `RawFormatRegistry.format(for:)`: resolves a file URL to `SonyRawFormat`, `NikonRawFormat`, `DNGRawFormat`, or `nil`.
- `SonyRawFormat`: `RawFormat` conformer for `.arw`.
- `NikonRawFormat`: `RawFormat` conformer for `.nef`.
- `DNGRawFormat`: `RawFormat` conformer for `.dng`.

```swift
import RawParserKit

let url = URL(fileURLWithPath: "/photos/frame.ARW")

if let format = RawFormatRegistry.format(for: url) {
    let thumbnail = try await format.extractThumbnail(
        from: url,
        maxDimension: 512,
        qualityCost: 4
    )

    let preview = await format.extractEmbeddedPreview(from: url, fullSize: false)
    let focus = format.focusLocation(from: url)
    let rawType = format.rawFileTypeString(compressionCode: 7)
    let sizeClass = format.rawSizeClass(width: 9504, height: 6336, camera: "ILCE-7RM5")
}
```

### High-Level Image Loading

Use `RawImageLoader.shared` for app/browser-style loading with task deduplication and concurrency limits.

- `thumbnail(for:maxPixelSize:) async -> NSImage?`: loads a rendered-image or RAW thumbnail.
- `thumbnailCGImage(for:maxPixelSize:) async -> CGImage?`: loads the same thumbnail as a `CGImage`.
- `previewImage(for:) async -> CGImage?`: loads a sidecar JPG when present, otherwise extracts an embedded RAW preview.
- `metadata(for:) async -> RawImageMetadata?`: reads display-ready EXIF rows, RAW metadata, and focus point information.

```swift
let image = await RawImageLoader.shared.thumbnail(for: url, maxPixelSize: 240)
let cgImage = await RawImageLoader.shared.thumbnailCGImage(for: url, maxPixelSize: 240)
let preview = await RawImageLoader.shared.previewImage(for: url)
let metadata = await RawImageLoader.shared.metadata(for: url)
```

`RawImageMetadata` contains optional `camera`, `lens`, `exposure`, `aperture`, `apertureValue`, `focalLength`, `iso`, `isoValue`, `capturedAt`, `dimensions`, `focusPoint`, `rawFileType`, `rawSizeClass`, `pixelWidth`, and `pixelHeight` fields. Its `rows` property returns display labels and values for non-empty fields, and `isEmpty` reports whether there is anything to show.

`RawFocusPoint` stores `normalizedX` and `normalizedY` coordinates. It can also parse the MakerNote focus-location string returned by `focusLocation(from:)`.

The older `thumbnail200px(for:targetSize:)`, `extractembeddedJPG(for:)`, `exifInfo(for:)`, `BrowserExifInfo`, and `BrowserFocusPoint` names remain available as deprecated compatibility shims.

### Thumbnail And Preview Extraction

Use the format-neutral `RawFormat` APIs where possible. The vendor-specific extractors are public when callers need direct access.

- `SonyThumbnailExtractor.extractSonyThumbnail(from:maxDimension:qualityCost:) async throws -> CGImage`
- `NikonThumbnailExtractor.extractNikonThumbnail(from:maxDimension:qualityCost:) async throws -> CGImage`
- `DNGThumbnailExtractor.extractDNGThumbnail(from:maxDimension:qualityCost:) async throws -> CGImage`
- `SonyEmbeddedJPEGExtractor.extractEmbeddedJPEG(from:fullSize:limiter:) async -> CGImage?`
- `NikonEmbeddedJPEGExtractor.extractEmbeddedJPEG(from:fullSize:limiter:) async -> CGImage?`
- `DNEmbeddedJPEGExtractor.extractEmbeddedJPEG(from:fullSize:limiter:) async -> CGImage?`
- `ThumbnailSharpener.sharpenedPreview(from:maxDimension:amount:) -> CGImage?`

```swift
let thumbnail = try await SonyThumbnailExtractor.extractSonyThumbnail(
    from: url,
    maxDimension: 512
)

let embeddedPreview = await SonyEmbeddedJPEGExtractor.extractEmbeddedJPEG(
    from: url,
    fullSize: true
)
```

`fullSize: true` allows previews up to 8640 px on the longest edge. `fullSize: false` downsamples large embedded previews to 4320 px.

The older `JPGSonyARWExtractor.jpgSonyARWExtractor(...)` and `JPGNikonNEFExtractor.jpgNikonNEFExtractor(...)` entrypoints remain available as deprecated compatibility shims.

### Sony Full-Size JPEG Creation

`SonyRawFormat.createFullSizeJPEG(from:quality:)` develops Sony ARW sensor data through macOS `CIRAWFilter` and encodes it as sRGB JPEG data.

```swift
let jpegData = try await SonyRawFormat.createFullSizeJPEG(
    from: url,
    quality: 1.0
)
```

This does not use the camera's embedded JPEG. Camera and compression-mode support follows the RAW decoder installed with macOS. Unsupported files throw `SonyJPEGCreationError.unsupportedOrInvalidRAW`.

`SonyJPEGCreationError` cases:

- `invalidQuality(Double)`
- `unsupportedOrInvalidRAW`
- `encodingFailed`

### MakerNote Parsing

Focus-location APIs return a string in RawCull's existing shape:

```text
"imageWidth imageHeight focusX focusY"
```

Public parser APIs:

- `SonyMakerNoteParser.focusLocation(from:) -> String?`
- `SonyMakerNoteParser.focusLocationDiagnostics(from:) -> RawParserDiagnostics<String>`
- `SonyMakerNoteParser.embeddedJPEGLocations(from:) -> EmbeddedJPEGLocations?`
- `SonyMakerNoteParser.embeddedJPEGLocationsDiagnostics(from:) -> RawParserDiagnostics<EmbeddedJPEGLocations>`
- `SonyMakerNoteParser.readEmbeddedJPEGData(at:from:) -> Data?`
- `NikonMakerNoteParser.focusLocation(from:) -> String?`
- `NikonMakerNoteParser.focusLocationDiagnostics(from:) -> RawParserDiagnostics<String>`
- `NikonMakerNoteParser.embeddedJPEGLocations(from:) -> NEFEmbeddedJPEGLocations?`
- `NikonMakerNoteParser.embeddedJPEGLocationsDiagnostics(from:) -> RawParserDiagnostics<NEFEmbeddedJPEGLocations>`
- `NikonMakerNoteParser.readEmbeddedJPEGData(at:from:) -> Data?`
- `DNGMakerNoteParser.focusLocation(from:) -> String?`
- `DNGMakerNoteParser.focusLocationDiagnostics(from:) -> RawParserDiagnostics<String>`
- `DNGMakerNoteParser.embeddedJPEGLocations(from:) -> DNGEmbeddedJPEGLocations?`
- `DNGMakerNoteParser.embeddedJPEGLocationsDiagnostics(from:) -> RawParserDiagnostics<DNGEmbeddedJPEGLocations>`
- `DNGMakerNoteParser.readEmbeddedJPEGData(at:from:) -> Data?`

```swift
let sonyFocus = SonyMakerNoteParser.focusLocation(from: url)
let nikonFocus = NikonMakerNoteParser.focusLocation(from: url)

let diagnostics = SonyMakerNoteParser.focusLocationDiagnostics(from: url)
if let focus = diagnostics.value {
    print("Focus:", focus)
} else {
    print("Failure:", diagnostics.failure ?? "unknown")
    print(diagnostics.trace.joined(separator: "\n"))
}
```

Sony embedded JPEG locations are represented by `EmbeddedJPEGLocations` with `thumbnail`, `preview`, and `fullJPEG` fields. Nikon embedded JPEG locations are represented by `NEFEmbeddedJPEGLocations` with `preview` and `ifd1JPEG` fields. DNG locations are represented by `DNGEmbeddedJPEGLocations` with `thumbnail`, `preview`, and `fullJPEG` fields. Each location has an absolute file `offset` and byte `length`.

For standards-classified DNGs, preview discovery uses TIFF `NewSubFileType` and `Compression` metadata across IFD0 and its SubIFDs. This prevents a JPEG-compressed raw strip in a full-resolution IFD from being mistaken for a rendered preview. Files that omit `NewSubFileType` retain the legacy positional fallback.

```swift
if let locations = SonyMakerNoteParser.embeddedJPEGLocations(from: url),
   let location = locations.preview ?? locations.fullJPEG,
   let data = SonyMakerNoteParser.readEmbeddedJPEGData(at: location, from: url) {
    print("JPEG bytes:", data.count)
}
```

`RawParserDiagnostics<Value>` contains:

- `value: Value?`
- `trace: [String]`
- `failure: String?`

### Orientation-Normalized Image Loading

`OrientationNormalizedImageLoader` provides lower-level ImageIO helpers for rendered images and embedded previews.

- `loadCGImage(from url:) -> CGImage?`
- `loadCGImage(from data:) -> CGImage?`
- `loadThumbnail(from:maxPixelSize:) -> CGImage?`
- `loadEmbeddedThumbnail(from:maxPixelSize:) -> CGImage?`
- `applyingSourceOrientation(to:from:) -> CGImage?`
- `loadSonyEmbeddedPreview(from:) -> CGImage?`
- `loadEmbeddedPreview(from:sourceURL:) -> CGImage?`

`SupportedFileType` enumerates `.arw`, `.nef`, `.jpeg`, `.jpg`, `.png`, `.tif`, and `.tiff`.

### Cancellation And Decode Limiting

- `CancellableImageIOWork.run(qos:_:) async throws -> Success`: runs synchronous ImageIO work on a global queue with a cooperative cancellation token.
- `CancellableImageIOWork.runReturningNilOnCancellation(qos:_:) async -> Success?`: converts cancellation and thrown errors to `nil`.
- `ImageIOCancellationToken.cancel()`, `isCancelled`, and `checkCancellation()`.
- `DecodeConcurrencyLimiter(maxConcurrent:)`: actor that bounds expensive async decode work.
- `DecodeConcurrencyLimiter.run(_:) async -> T?`: runs work once a slot is available and returns `nil` if cancelled before or during execution.

### Errors

`ThumbnailError` cases:

- `invalidSource`
- `generationFailed`
- `contextCreationFailed`

`SonyJPEGCreationError` cases are listed in the Sony full-size JPEG section.

## Concurrency Notes

The public APIs are non-UI and do not depend on SwiftUI, `@Observable`, RawCull view models, or app state. ImageIO thumbnail and JPEG work is wrapped by `CancellableImageIOWork`, which schedules synchronous ImageIO operations on a global queue and resumes the async caller when the work completes or cancellation is observed.

The parser code itself is pure Foundation-based binary reading. It reads either a fast-path prefix window or a full-file fallback, then walks TIFF IFD structures and vendor MakerNote data.

## Development

Build the package:

```bash
swift build
```

Run tests:

```bash
swift test
```

Run tests with code coverage:

```bash
swift test --enable-code-coverage
```

## Test Strategy

The test suite uses Swift Testing and synthetic binary data. It does not require real ARW, NEF, or DNG files. The tests cover:

- Sony focus-location MakerNote variants
- Nikon focus-location MakerNote variants
- DNG format metadata and TIFF IFD/SubIFD preview discovery
- Embedded JPEG offset discovery and JPEG byte reading
- Thumbnail and JPEG extraction cancellation behavior
- Raw format registry extension matching

## Adding A Vendor

Add a new `RawFormat` conformer for the vendor, implement its parser/extractor entrypoints, and register the conformer in `RawFormatRegistry.all`. Prefer synthetic binary fixtures for parser tests so the package remains fast and deterministic.
