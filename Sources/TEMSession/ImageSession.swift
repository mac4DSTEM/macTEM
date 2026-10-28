//
//  ImageSession.swift
//  Role: the one owner of the open image — what was read, from where, and whether a read is running.
//        The read itself happens off the main actor (`AppState.read`, which calls TEMCore's
//        `ImageOpening.openNow` and `AcquisitionMetadata.read(path:)`); this owner only publishes its result, and
//        only the result of the latest open: an earlier, slower read that finishes second is dropped, never shown
//        over the newer image, and its failure is not reported over it either. The image and what its file records
//        about the acquisition are published together under the one token, so the metadata held
//        is always the held image's own. Nothing reads `metadata` yet: the panel is a later slice.
//

import Foundation
import Observation
#if canImport(TEMCore)
import FormatoCore
import TEMCore
#endif

@Observable
package final class ImageSession {
    package private(set) var image: CalibratedImage?
    /// What the file of `image` records about how it was acquired; empty ("not recorded" in every
    /// field) when there is no image or the file records nothing. Set with `image`, by the same open, never apart.
    package private(set) var metadata = AcquisitionMetadata()
    /// The file the image came from (the sandbox granted it by the open panel or Finder).
    package private(set) var url: URL?
    package private(set) var isLoading = false
    @ObservationIgnored private var latestOpen = 0

    package init() {}

    /// Starts an open and returns its token; any open still running is superseded.
    package func beginOpen() -> Int {
        latestOpen &+= 1
        isLoading = true
        return latestOpen
    }

    /// Publishes the open `token` started: the image, its file and the file's acquisition metadata, together. Returns
    /// false, changing nothing, when a later open superseded it. `metadata` has no default: an open that forgets it
    /// would leave the previous file's values under the new image.
    @discardableResult
    package func finishOpen(_ token: Int, image: CalibratedImage, url: URL, metadata: AcquisitionMetadata) -> Bool {
        guard token == latestOpen else { return false }
        self.image = image
        self.url = url
        self.metadata = metadata
        isLoading = false
        return true
    }

    /// Ends the open `token` started without an image; the image already shown stays. Returns false, changing
    /// nothing, when a later open superseded it — its failure is then no longer the user's news.
    @discardableResult
    package func failOpen(_ token: Int) -> Bool {
        guard token == latestOpen else { return false }
        isLoading = false
        return true
    }
}
