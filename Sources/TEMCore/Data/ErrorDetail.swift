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

    /// An error the system made (an `NSError`, or Foundation's Cocoa, POSIX or URL error), not one of the app's own.
    private static func isSystem(_ error: any Error) -> Bool {
        type(of: error) is NSError.Type || error is CocoaError || error is POSIXError || error is URLError
    }
}
