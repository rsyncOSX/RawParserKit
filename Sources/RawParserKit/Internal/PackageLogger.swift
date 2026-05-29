//
//  PackageLogger.swift
//  RawParserKit
//
//  Created by Thomas Evensen on 29/05/2026.
//

import OSLog

extension Logger {
    nonisolated static let process = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.rsyncprocessstreaming",
        category: "process"
    )

    nonisolated func debugMessage(_ message: String) {
        #if DEBUG
            debug("\(message)")
        #endif
    }

    nonisolated func debugWithThreadInfo(_ message: String) {
        #if DEBUG
            if Thread.isMainThread {
                debug("\(message) Running on main thread")
            } else {
                debug("\(message) NOT on main thread, currently on \(Thread.current)")
            }
        #endif
    }
}

