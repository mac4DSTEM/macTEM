//
//  SecurityScopedBookmarkTests.swift
//  Pins `SecurityScopedBookmark.make`, the one bookmark maker behind the open-files list, the session save and the
//  session restore: read-write first, read-only when the sandbox refuses read-write, the error when it refuses both.
//  Each test names the change to the production code that turns it red.
//

import XCTest
import Foundation
import TEMSession

nonisolated final class SecurityScopedBookmarkTests: XCTestCase {
    /// A file the sandbox lets the app read but not write (a pick on a read-only volume, a read-only grant) refuses a
    /// read-write security-scoped bookmark with NSCocoaErrorDomain 256; the maker then keeps a read-only one, so the file
    /// can be reopened. Red under: dropping the read-only fallback (the refusal is thrown).
    func testBookmarkFallsBackToReadOnlyScopeWhenReadWriteIsRefused() throws {
        let url = URL(fileURLWithPath: "/Volumes/ReadOnly/scan.dm4")
        var asked: [URL.BookmarkCreationOptions] = []
        let data = try SecurityScopedBookmark.make(for: url) { _, options in
            asked.append(options)
            guard options.contains(.securityScopeAllowOnlyReadAccess) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
            }
            return Data([7])
        }
        XCTAssertEqual(data, Data([7]))
        XCTAssertEqual(asked, [[.withSecurityScope], [.withSecurityScope, .securityScopeAllowOnlyReadAccess]])
    }

    /// A writable file keeps its read-write grant: the read-only option is never asked for. Red under: asking for
    /// read-only first.
    func testBookmarkStaysReadWriteWhenAllowed() throws {
        var asked: [URL.BookmarkCreationOptions] = []
        let data = try SecurityScopedBookmark.make(for: URL(fileURLWithPath: "/tmp/a.dm4")) { _, options in
            asked.append(options); return Data([1])
        }
        XCTAssertEqual(data, Data([1]))
        XCTAssertEqual(asked, [[.withSecurityScope]])
    }

    /// Both refused (no access at all): the error still reaches the caller, whose `try?` keeps the item without a
    /// bookmark. Red under: swallowing the second error and returning empty data.
    func testBookmarkThrowsWhenNeitherScopeIsGranted() {
        XCTAssertThrowsError(try SecurityScopedBookmark.make(for: URL(fileURLWithPath: "/x.dm4")) { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        })
    }
}
