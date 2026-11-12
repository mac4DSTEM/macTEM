//
//  ErrorDetail.swift
//  Role: the words an alert, a status line or a reader's refusal gives for an error. The app's own errors read as they are written
//        (their `errorDescription`); a system error keeps its sentence and adds the Cocoa domain, the code and the underlying error,
//        as mac4DSTEM's `sessionErrorDetail` does and the sidecar layer here already did (`SessionSidecarFile`). Without them a
//        sandbox denial (NSPOSIXErrorDomain 1), a missing file (NSPOSIXErrorDomain 2) and an I/O error read the same, and the
//        readers' "could not be read." said none of them.
//

import Foundation

package nonisolated enum ErrorDetail {
    /// `error`'s sentence; for a system error followed by its domain and code and the underlying error's, as
    /// "The file “a.spc” couldn’t be opened because you don’t have permission to view it. (NSCocoaErrorDomain 257; underlying
    /// NSPOSIXErrorDomain 1)". An app error's bridged domain is its type's name and its code an enum index, so it adds nothing.
    package static func text(_ error: any Error) -> String {
        let sentence = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        guard isSystem(error) else { return sentence }
        let ns = error as NSError
        var code = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            code += "; underlying \(underlying.domain) \(underlying.code)"
        }
        return "\(sentence) (\(code))"
    }

    /// The alert's title for `error` (#529): a file that could not be opened says so; anything else stays "Something went wrong".
    package static func title(_ error: any Error) -> String {
        error is FileOpenFailure ? openTitle(files: 1) : genericTitle
    }

    /// The title of the alert that lists the files one Open refused.
    package static func openTitle(files: Int) -> String {
        files == 1 ? "macEM can't open this file" : "macEM can't open these files"
    }

    package static let genericTitle = "Something went wrong"

    /// An error the system made (an `NSError`, or Foundation's Cocoa, POSIX or URL error), not one of the app's own.
    private static func isSystem(_ error: any Error) -> Bool {
        type(of: error) is NSError.Type || error is CocoaError || error is POSIXError || error is URLError
    }
}

/// An error met while opening a file (#529), so the alert is titled "macEM can't open this file" and not "Something went wrong". Its
/// sentence is the underlying error's, with a system error's domain and code (`ErrorDetail.text`).
package nonisolated struct FileOpenFailure: Error, LocalizedError {
    package let underlying: any Error
    package init(_ underlying: any Error) { self.underlying = underlying }
    package var errorDescription: String? { ErrorDetail.text(underlying) }
}
