// Log.swift
// Glance
//
// Central OSLog channels. Everything the capture -> render -> window pipeline
// does is logged here so a failure can be traced end-to-end with:
//
//     log stream --style compact --predicate 'subsystem == "com.filippocappa.glance"' --level debug

import OSLog
import Foundation

enum Log {
    private static let subsystem = "com.filippocappa.glance"

    /// TCC / Screen Recording authorization.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    /// SCStream lifecycle, configuration and frame delivery.
    static let capture = Logger(subsystem: subsystem, category: "capture")

    /// CALayer / IOSurface presentation.
    static let render = Logger(subsystem: subsystem, category: "render")

    /// NSPanel creation, ordering and geometry.
    static let window = Logger(subsystem: subsystem, category: "window")

    /// Region selection overlay.
    static let selection = Logger(subsystem: subsystem, category: "selection")
}


// MARK: - Crash diagnostics

extension Log {

    /// Routes uncaught Objective-C exceptions into our own OSLog subsystem.
    ///
    /// AppKit swallows some exceptions raised during window resize without
    /// producing a crash report, which left a hard-to-reproduce resize crash
    /// with no evidence at all. Installing this means the reason and call stack
    /// land in `log stream` even when no .ips file is written.
    static func installCrashDiagnostics() {
        NSSetUncaughtExceptionHandler { exception in
            let symbols = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            Log.window.fault("""
                UNCAUGHT EXCEPTION \(exception.name.rawValue, privacy: .public): \
                \(exception.reason ?? "no reason", privacy: .public)
                \(symbols, privacy: .public)
                """)
        }
    }
}
