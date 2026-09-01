//
//  RawFormatRegistry.swift
//  RawCull
//
//  Dispatches by file extension to the matching `RawFormat` conformer.
//  Add a new brand by appending its conformer to `all`.
//

import Foundation

public enum RawFormatRegistry {
    public nonisolated static let all: [any RawFormat.Type] = [
        SonyRawFormat.self,
        NikonRawFormat.self,
        DNGRawFormat.self
    ]

    /// Union of extensions across every registered format.
    public nonisolated static var allExtensions: Set<String> {
        all.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
    }

    /// Resolves the format for a file URL by its lowercased extension.
    public nonisolated static func format(for url: URL) -> (any RawFormat.Type)? {
        let ext = url.pathExtension.lowercased()
        return all.first { $0.extensions.contains(ext) }
    }
}
