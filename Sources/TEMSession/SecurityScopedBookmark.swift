//
//  SecurityScopedBookmark.swift
//  The one place macTEM makes a security-scoped bookmark: read-write when the sandbox grants it, read-only otherwise.
//

import Foundation

package nonisolated enum SecurityScopedBookmark {
    /// A read-write security-scoped bookmark, or a read-only one when the sandbox grants only read access. In the
    /// sandbox a read-write bookmark fails (NSCocoaErrorDomain 256, "couldn't be opened") whenever the process may read
    /// the file but not write it: a file the user picked on a read-only volume (a disk image, a read-only share) or
    /// under a read-only grant. Without the fallback such a file got no bookmark and could not be reopened later
    /// (mac4DSTEM #132 measured the same refusal and the same fix). The read-write attempt stays first, so a writable
    /// file keeps a writable grant. `make` is the system's, injected so a test can stand for the sandbox's refusal.
    package static func make(
        for url: URL,
        make: (URL, URL.BookmarkCreationOptions) throws -> Data = { url, options in
            try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    ) throws -> Data {
        do {
            return try make(url, [.withSecurityScope])
        } catch {
            return try make(url, [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        }
    }
}
