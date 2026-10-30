//
//  ImageMeasurements.swift
//  Role: the one owner of the marks on one open file: distances, angles and line profiles, each its
//        points in the image's pixel coordinates (`ImagePoint`: column x, row y, a pixel's centre at integers), a
//        profile's width, and which mark is selected. The numbers are TEMCore's (`ImageMeasurement`, `LineProfile`,
//        gated against the closed form and scikit-image); this owner holds the marks and the profiles computed from
//        them, and — since V1-2 slice B — the file's session record: the live lineage (one node per mark, from the
//        first mark, ADR 020) and what saving and restoring it need.
//
//        A profile needs the pixels, so it is computed when its mark is made or changed, against the image the caller
//        passes (the file's own `CalibratedImage`, never the display canvas: no contrast setting reaches a number), and
//        again for every profile when the file is read again (`refresh`), in case the file changed on disk.
//
//        THE SESSION RECORD ("Slice B; the core"). Every mutator records: a new mark adds its node, a move
//        or a width change replaces it in place (R3), a removal removes it. Points and widths are clamped here as the
//        room clamps them (the image from −0.5 to W − 0.5; widths 1…25), so the owner never holds a mark the reader would
//        refuse. Nodes are a verbatim record: `refresh` and `restore` never rewrite one. A save is taken here as one
//        Sendable request (`saveRequest`) and written off the main actor (`SessionSave.write`); `didSave` then marks the
//        revision it wrote as saved. A restore (`SessionRestore.restore`, off the main actor) is adopted here in one
//        synchronous step, only into an owner that holds nothing. Not wired to the app yet: the menu, the panel, the
//        bookmark and restoring at a file's first read are the UI slice's.
//

import ImagoCore
import Foundation
import Observation
import TEMCore

/// One mark on an image.
package nonisolated struct ImageMark: Sendable, Equatable, Identifiable {
    package enum Kind: String, Sendable, Equatable, CaseIterable {
        case distance, angle, profile

        /// How many points the kind takes: a segment's two ends; an angle's A, its vertex B, and C.
        package var pointCount: Int { self == .angle ? 3 : 2 }
    }

    package let id: UUID
    package let kind: Kind
    /// `kind.pointCount` points; for an angle the middle one is the vertex.
    package var points: [ImagePoint]
    /// A profile's width in pixels (1 for the other kinds).
    package var width: Int

    package init(id: UUID = UUID(), kind: Kind, points: [ImagePoint], width: Int = 1) {
        precondition(points.count == kind.pointCount, "ImageMark: \(points.count) points for a \(kind)")
        self.id = id
        self.kind = kind
        self.points = points
        self.width = max(1, width)
    }

    /// The mark as the sidecar records it.
    package var sessionMark: SessionMark {
        let kind: SessionMark.Kind = switch self.kind {
        case .distance: .distance
        case .angle: .angle
        case .profile: .profile
        }
        return SessionMark(kind: kind, points: points, width: width)
    }

    /// A drawable mark from a recorded one (a new id: ids are the session's, the node's id is the sidecar's).
    package init(_ mark: SessionMark) {
        let kind: Kind = switch mark.kind {
        case .distance: .distance
        case .angle: .angle
        case .profile: .profile
        }
        self.init(kind: kind, points: mark.points, width: mark.width)
    }
}

@Observable
package final class ImageMeasurements {
    package private(set) var marks: [ImageMark] = []
    /// The selected mark (drawn in the accent colour; its profile is charted).
    package var selection: ImageMark.ID?
    /// The profile of each profile mark, computed from the image's pixels.
    package private(set) var profiles: [ImageMark.ID: LineProfile] = [:]

    /// The widest profile the Width control offers, in pixels (TEMCore's, which the sidecar's reader holds it to).
    package static let maximumWidth = SessionMarks.maximumWidth

    // MARK: The session record

    /// What became of this file's sidecar.
    package enum Sidecar: Equatable, Sendable {
        /// None restored or saved yet.
        case none
        /// Restored when the file was opened.
        case restored
        /// Refused when the file was opened, with the sentence why; saving waits for `replaceRefusedSidecar`.
        case refused(String)
        /// Written by this window.
        case saved
    }

    /// A fact about the marks a reader should see beside them; cleared by a save.
    package enum Note: Equatable, Sendable {
        /// The image's pixels are not the ones the marks were drawn on.
        case pixelsDiffer
        /// The marks were saved for a file of another name.
        case renamed(from: String)
        /// A restored mark was measured with other scales or units than the file has now.
        case calibrationDiffers

        package var sentence: String {
            switch self {
            case .pixelsDiffer: "The image differs from when the marks were drawn."
            case .renamed(let name): "The marks were saved for “\(name)”."
            case .calibrationDiffers: "The image's calibration differs from when the marks were measured."
            }
        }
    }

    package enum RestoreRefusal: Error, Equatable, Sendable {
        /// A restore adopts only into an owner that holds no mark and no node, so it never replaces unsaved work.
        case notEmpty
    }

    /// One node per mark, from the first mark; other kinds and removed nodes a restore kept.
    package private(set) var lineage = SessionLineage()
    package private(set) var sidecar = Sidecar.none
    package private(set) var notes: [Note] = []
    /// Raised by every change to the lineage; the file is saved when the sidecar holds this revision.
    package private(set) var revision = 0
    package private(set) var savedRevision = 0
    package var isDirty: Bool { revision != savedRevision }

    /// Why a new mark would not be recorded now, or nil: what the tools ask before a gesture. The one place the limits meet
    /// (`mintRefusal`'s: a read-only lineage, 2 000 nodes, every id spent; and ADR 023's byte budget: the smallest node a mark
    /// can record would take the saved text past `SessionSidecarFile.maxTotalTextBytes`). `add` is the exact check.
    package var recordingRefusal: SessionLineage.Refusal? {
        if let refusal = lineage.mintRefusal { return refusal }
        guard let lineageBytes = Self.lineageBytes(lineage) else { return .tooLargeToSave(bytes: SessionLineage.maximumJSONBytes, limit: SessionSidecarFile.maxTotalTextBytes) }
        let total = SessionSidecarFile.totalTextBytes(sourceBytes: sourceBytes, lineageBytes: lineageBytes + SessionMarks.smallestNodeBytes)
        return total > SessionSidecarFile.maxTotalTextBytes ? .tooLargeToSave(bytes: total, limit: SessionSidecarFile.maxTotalTextBytes) : nil
    }

    /// The bytes of the source identity a save would write: the opened image's, once known, else a reserve for a typical one.
    private var sourceBytes: Int {
        guard let drawnOn, let text = try? drawnOn.jsonString() else { return Self.sourceReserveBytes }
        return text.utf8.count
    }
    /// What the source identity is assumed to take before the first image identity is known (a 60-character file name, an
    /// object, a shape and the 64-digit fingerprint come to about 250).
    private static let sourceReserveBytes = 512

    private static func lineageBytes(_ lineage: SessionLineage) -> Int? {
        // try? OK: a lineage that cannot be written (over the 4 MiB cap) is over the budget; the caller says so.
        (try? lineage.jsonString())?.utf8.count
    }

    /// ADR 023 a: the refusal for a lineage that, saved, would hold more than a sidecar may, or nil.
    private func budgetRefusal(of candidate: SessionLineage) -> SessionLineage.Refusal? {
        let limit = SessionSidecarFile.maxTotalTextBytes
        guard let bytes = Self.lineageBytes(candidate) else { return .tooLargeToSave(bytes: SessionLineage.maximumJSONBytes, limit: limit) }
        let total = SessionSidecarFile.totalTextBytes(sourceBytes: sourceBytes, lineageBytes: bytes)
        return total > limit ? .tooLargeToSave(bytes: total, limit: limit) : nil
    }

    /// Why a save would be refused before it is tried, or nil.
    package var savingRefusal: SessionSave.Refusal? {
        if lineage.isReadOnly { return .readOnly(lineage.fileVersion) }
        if case .refused(let reason) = sidecar, !replacing { return .sidecarRefused(reason) }
        return nil
    }

    @ObservationIgnored private var nodeIDs: [ImageMark.ID: String] = [:]
    /// The identity of the image the marks were drawn on: set by `noteOpened` while nothing is drawn, a restore or a save.
    @ObservationIgnored private var drawnOn: SessionSourceIdentity?
    /// The lineage the sidecar on disk held when it was restored or last saved; a save checks it is still there.
    @ObservationIgnored private var onDisk: String?
    @ObservationIgnored private var replacing = false
    /// The pixels the user chose Save Anyway for after a re-read: a save of exactly those takes the new image.
    @ObservationIgnored private var acceptedPixels: String?
    @ObservationIgnored private let now: @Sendable () -> Date

    /// `now` stamps every node's `recorded` (a test passes its own clock).
    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    package func mark(_ id: ImageMark.ID?) -> ImageMark? {
        guard let id else { return nil }
        return marks.first { $0.id == id }
    }

    /// The lineage node of mark `id`, or nil (a mark drawn on a read-only lineage has none).
    package func nodeID(of id: ImageMark.ID) -> String? { nodeIDs[id] }

    // MARK: Marks

    /// Adds `mark`, clamped to the image (a profile's width too; another kind's width is not recorded), records its node
    /// and selects it. A lineage that can take no node (full, or a
    /// newer version's) refuses it: the refusal is returned and the mark is not added — except on a read-only lineage,
    /// where marks are drawn and not recorded (its saving is refused).
    @discardableResult
    package func add(_ mark: ImageMark, on image: CalibratedImage) -> SessionLineage.Refusal? {
        guard mark.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .notFinite }
        let mark = Self.clamped(mark, to: image)
        let profile = Self.profile(of: mark, on: image)
        if !lineage.isReadOnly {
            do throws(SessionLineage.Refusal) {
                let session = mark.sessionMark
                var candidate = lineage
                let id = try candidate.add(kind: session.kind.rawValue,
                                           parameters: SessionMarks.parameters(of: session, object: image.source),
                                           results: SessionMarks.results(of: session, x: image.x, y: image.y,
                                                                         samples: profile?.samples.count),
                                           recorded: SessionLineage.milliseconds(now()))
                if let refusal = budgetRefusal(of: candidate) { return refusal }
                lineage = candidate
                nodeIDs[mark.id] = id
                revision += 1
            } catch {
                return error
            }
        }
        marks.append(mark)
        selection = mark.id
        if let profile { profiles[mark.id] = profile }
        return nil
    }

    /// Moves point `index` of mark `id` to `point` (a dragged endpoint), clamped to the image.
    package func move(_ id: ImageMark.ID, point index: Int, to point: ImagePoint, on image: CalibratedImage) {
        guard let i = marks.firstIndex(where: { $0.id == id }), marks[i].points.indices.contains(index) else { return }
        guard point.x.isFinite, point.y.isFinite else { return }
        let point = Self.clamped(point, to: image)
        guard marks[i].points[index] != point else { return }
        let before = marks[i].points[index]
        marks[i].points[index] = point
        if !changed(marks[i], on: image) { marks[i].points[index] = before }
    }

    /// Sets a profile's width (1…`maximumWidth` px).
    package func setWidth(_ id: ImageMark.ID, _ width: Int, on image: CalibratedImage) {
        guard let i = marks.firstIndex(where: { $0.id == id }), marks[i].kind == .profile else { return }
        let clamped = min(max(width, 1), Self.maximumWidth)
        guard marks[i].width != clamped else { return }
        let before = marks[i].width
        marks[i].width = clamped
        if !changed(marks[i], on: image) { marks[i].width = before }
    }

    package func remove(_ id: ImageMark.ID) {
        if let node = nodeIDs.removeValue(forKey: id) {
            lineage.remove(id: node, at: SessionLineage.milliseconds(now()))
            revision += 1
        }
        marks.removeAll { $0.id == id }
        profiles[id] = nil
        if selection == id { selection = nil }
    }

    /// Removes every mark and its node; nodes of other kinds stay (a cited mark node stays dated, as `remove` keeps it).
    package func removeAll() {
        let at = SessionLineage.milliseconds(now())
        for mark in marks {
            if let node = nodeIDs[mark.id] {
                lineage.remove(id: node, at: at)
                revision += 1
            }
        }
        nodeIDs = [:]
        marks = []
        profiles = [:]
        selection = nil
    }

    /// Every profile again, against `image` (the file was read again). The nodes are not touched.
    package func refresh(on image: CalibratedImage) {
        for mark in marks where mark.kind == .profile { profiles[mark.id] = Self.profile(of: mark, on: image) }
    }

    /// The identity of the image a read has just opened (computed off the main actor by the caller). While nothing is
    /// drawn it is the image the marks will be drawn on; a later one with other pixels, while there are marks, notes that
    /// they differ.
    package func noteOpened(_ identity: SessionSourceIdentity) {
        guard let drawnOn, !marks.isEmpty || !lineage.nodes.isEmpty else { self.drawnOn = identity; return }
        if drawnOn.pixelSHA256 != identity.pixelSHA256, !lineage.nodes.isEmpty || !marks.isEmpty,
           !notes.contains(.pixelsDiffer) {
            notes.append(.pixelsDiffer)
        }
    }

    // MARK: Save

    /// What a save of this file's marks writes: the opened image's identity and the lineage, every mark node checked with
    /// the restore's own checks. Take it on the main actor; write it with `SessionSave.write` off it; then `didSave`.
    package func saveRequest(opened identity: SessionSourceIdentity) throws(SessionSave.Refusal) -> SessionSave.Request {
        if let refusal = savingRefusal { throw refusal }
        if acceptedPixels != identity.pixelSHA256, let drawnOn, drawnOn.pixelSHA256 != identity.pixelSHA256,
           !marks.isEmpty || !lineage.nodes.isEmpty {
            throw .pixelsChanged
        }
        return try SessionSave.request(identity: identity, lineage: lineage, revision: revision,
                                       expectedOnDisk: onDisk, replacing: replacing)
    }

    /// `request` was written: its revision is saved (a mark changed during the write leaves the file unsaved), the image
    /// it describes is the one the marks are drawn on, and the notes are answered.
    package func didSave(_ request: SessionSave.Request, opened identity: SessionSourceIdentity) {
        savedRevision = request.revision
        onDisk = request.lineage
        replacing = false
        acceptedPixels = nil
        sidecar = .saved
        drawnOn = identity
        notes = []
    }

    /// The user chose to replace the sidecar on disk (one refused when the file was opened, or one this window never
    /// read): the next save writes over it.
    package func replaceRefusedSidecar() {
        replacing = true
    }

    /// The user chose Save Anyway after a re-read with other pixels: a save of `identity`'s pixels writes the marks
    /// against them; a read of yet other pixels is refused again.
    package func acceptNewPixels(_ identity: SessionSourceIdentity) {
        acceptedPixels = identity.pixelSHA256
    }

    // MARK: Restore

    /// Adopts a restore of this file's sidecar, whole and at once: the lineage as read, the marks it draws (each
    /// profile measured again on `image`'s own pixels), the notes the verdict and the calibration call for. Refused,
    /// changing nothing, unless the owner holds no mark and no node.
    package func restore(_ restored: SessionRestore.Restored, opened identity: SessionSourceIdentity,
                         on image: CalibratedImage) throws(RestoreRefusal) {
        guard marks.isEmpty, lineage.nodes.isEmpty, lineage.nextID == 1, !lineage.isReadOnly else { throw .notEmpty }
        var newMarks: [ImageMark] = []
        var newIDs: [ImageMark.ID: String] = [:]
        var newProfiles: [ImageMark.ID: LineProfile] = [:]
        for entry in restored.marks {
            let mark = ImageMark(entry.mark)
            newMarks.append(mark)
            newIDs[mark.id] = entry.nodeID
            if let profile = Self.profile(of: mark, on: image) { newProfiles[mark.id] = profile }
        }
        var newNotes: [Note] = []
        switch restored.verdict {
        case .adoptPixelsDiffer: newNotes.append(.pixelsDiffer)
        case .adoptRenamed(let name): newNotes.append(.renamed(from: name))
        case .adopt, .refuse: break
        }
        if restored.calibrationDiffers { newNotes.append(.calibrationDiffers) }

        lineage = restored.lineage
        marks = newMarks
        nodeIDs = newIDs
        profiles = newProfiles
        selection = nil
        notes = newNotes
        sidecar = .restored
        onDisk = restored.lineageText
        drawnOn = identity
        replacing = false
        savedRevision = revision
    }

    /// The sidecar beside the file was refused or could not be read when the file was opened: saving waits for the
    /// user's choice to replace it.
    package func sidecarRefused(_ reason: String) {
        sidecar = .refused(reason)
    }

    // MARK: Helpers

    /// Records the change of `mark` in its node (R3). False, changing nothing, when the replaced node would take the saved
    /// text past the budget: the caller puts the mark back.
    private func changed(_ mark: ImageMark, on image: CalibratedImage) -> Bool {
        let profile = Self.profile(of: mark, on: image)
        guard let node = nodeIDs[mark.id] else { profiles[mark.id] = profile; return true }
        let session = mark.sessionMark
        var candidate = lineage
        if candidate.replace(id: node, parameters: SessionMarks.parameters(of: session, object: image.source),
                             results: SessionMarks.results(of: session, x: image.x, y: image.y,
                                                           samples: profile?.samples.count),
                             recorded: SessionLineage.milliseconds(now())) {
            if budgetRefusal(of: candidate) != nil { return false }
            lineage = candidate
            revision += 1
        }
        profiles[mark.id] = profile
        return true
    }

    private static func profile(of mark: ImageMark, on image: CalibratedImage) -> LineProfile? {
        guard mark.kind == .profile else { return nil }
        return LineProfile.sample(image, from: mark.points[0], to: mark.points[1], width: mark.width)
    }

    private static func clamped(_ point: ImagePoint, to image: CalibratedImage) -> ImagePoint {
        ImagePoint(x: min(max(point.x, -0.5), Double(image.width) - 0.5),
                   y: min(max(point.y, -0.5), Double(image.height) - 0.5))
    }

    private static func clamped(_ mark: ImageMark, to image: CalibratedImage) -> ImageMark {
        ImageMark(id: mark.id, kind: mark.kind, points: mark.points.map { clamped($0, to: image) },
                  width: mark.kind == .profile ? min(max(mark.width, 1), maximumWidth) : mark.width)
    }
}
