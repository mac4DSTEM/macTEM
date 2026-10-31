//
//  ImageMeasurementsSessionTests.swift
//  The session record of `ImageMeasurements`, the one owner of the marks on a file (the core):
//  every mutator records (a new mark adds its node, a move or a width change replaces it in place, R3; a removal removes
//  it), points and widths are clamped as the room clamps them, a lineage that can take no node refuses the mark by name,
//  a read-only lineage draws and records nothing, a save is one Sendable request and `didSave` marks its revision saved, a
//  restore is adopted whole and only into an owner that holds nothing, and a restore equals the save (P1). The pure parts
//  (a mark to a node and back, the checks, `SessionRestore`, `SessionSave`) are `SessionMarksTests`'; the format against
//  h5py is tools/parity/sidecar-parity. Planted on a 40 × 24 image with anisotropic axes (0.5 nm a column, 2 nm a row) so an x
//  taken for a y shows. A test passes its own clock; every `Red under:` names the mutation of ImageMeasurements.swift (or
//  of SessionMarks.swift) the test was broken by.
//

import ImagoCore
import XCTest
import Foundation
import TEMCore
import TEMSession

/// A clock the owner reads and a test sets.
nonisolated final class SessionTestClock: @unchecked Sendable {
    var milliseconds: Int64 = 1_791_900_000_000
    var date: Date { SessionLineage.date(milliseconds: milliseconds) }
}

nonisolated final class ImageMeasurementsSessionTests: XCTestCase {
    private let t0: Int64 = 1_791_900_000_000

    nonisolated private static func image(width: Int = 40, height: Int = 24, shift: Int = 0,
                                          x: AxisCalibration? = AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                                          y: AxisCalibration? = AxisCalibration(scale: 2.0, unit: "nm", origin: 0),
                                          fileName: String = "scan.dm4", source: String = "ImageList.1") -> CalibratedImage {
        CalibratedImage(width: width, height: height,
                        pixels: (0..<width * height).map { Float(($0 * 37 + ($0 / width) * 11 + shift * 31) % 97) },
                        x: x, y: y, fileName: fileName, source: source, voltage: nil)
    }

    @MainActor private func owner(_ clock: SessionTestClock) -> ImageMeasurements {
        ImageMeasurements(now: { clock.date })
    }

    private func distance(_ a: (Double, Double), _ b: (Double, Double)) -> ImageMark {
        ImageMark(kind: .distance, points: [ImagePoint(x: a.0, y: a.1), ImagePoint(x: b.0, y: b.1)])
    }

    private func profile(_ a: (Double, Double), _ b: (Double, Double), width: Int = 1) -> ImageMark {
        ImageMark(kind: .profile, points: [ImagePoint(x: a.0, y: a.1), ImagePoint(x: b.0, y: b.1)], width: width)
    }

    private func angle() -> ImageMark {
        ImageMark(kind: .angle, points: [ImagePoint(x: 10.5, y: 3.25), ImagePoint(x: 4, y: 12.75), ImagePoint(x: 34.25, y: 20.5)])
    }

    @MainActor private func node(_ id: ImageMark.ID, in owner: ImageMeasurements, file: StaticString = #filePath,
                                 line: UInt = #line) -> SessionLineage.Node? {
        guard let nodeID = owner.nodeID(of: id), let node = owner.lineage.node(id: nodeID) else {
            XCTFail("the mark has no node", file: file, line: line)
            return nil
        }
        return node
    }

    private func identity(of image: CalibratedImage) -> SessionSourceIdentity {
        SessionSourceIdentity.of(image, fileByteSize: 4096)
    }

    private func contents(_ identity: SessionSourceIdentity, _ lineage: SessionLineage) throws -> SessionSidecarFile.Contents {
        SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try identity.jsonString(), lineage: try lineage.jsonString())
    }

    /// The restore the pure part gives for `contents` read for an image `opened` with the axes of `image`.
    private func restored(_ contents: SessionSidecarFile.Contents, opened: SessionSourceIdentity, image: CalibratedImage,
                          file: StaticString = #filePath, line: UInt = #line) -> SessionRestore.Restored? {
        do throws(SessionRestore.Refusal) {
            return try SessionRestore.restore(contents, opened: opened, x: image.x, y: image.y)
        } catch {
            XCTFail("refused: \(error)", file: file, line: line)
            return nil
        }
    }

    /// An owner restored from `lineage` (as read for `image`), or nil with a failure.
    @MainActor private func restoredOwner(_ lineage: SessionLineage, image: CalibratedImage, clock: SessionTestClock,
                                          file: StaticString = #filePath, line: UInt = #line) throws -> ImageMeasurements {
        let identity = identity(of: image)
        let result = try XCTUnwrap(restored(try contents(identity, lineage), opened: identity, image: image), file: file, line: line)
        let target = owner(clock)
        try target.restore(result, opened: identity, on: image)
        return target
    }

    // MARK: Recording

    /// A new mark is clamped to the image — a point to −0.5…W − 0.5 and −0.5…H − 0.5, as the room clamps it — and its node
    /// holds the clamped point; a point exactly on an edge is kept; a dragged endpoint is clamped too. An angle's three
    /// points are all clamped. Red under: the clamp removed from `add` (the node then holds 1000.0); the bound at 0 or at W
    /// (a point on the edge moves, or 40.0 is kept); x clamped to the height or y to the width; `move` unclamped.
    @MainActor func testAMarkIsClampedToTheImageAndItsNodeHoldsTheClampedPoints() throws {
        let image = Self.image(), clock = SessionTestClock()
        let o = owner(clock)
        o.add(distance((-5, 100), (1000, -3)), on: image)
        XCTAssertEqual(o.marks[0].points, [ImagePoint(x: -0.5, y: 23.5), ImagePoint(x: 39.5, y: -0.5)])
        let first = try XCTUnwrap(node(o.marks[0].id, in: o))
        XCTAssertEqual([first.parameters["x1"], first.parameters["y1"], first.parameters["x2"], first.parameters["y2"]],
                       ["-0.5", "23.5", "39.5", "-0.5"])
        o.add(distance((-0.5, -0.5), (39.5, 23.5)), on: image)
        XCTAssertEqual(o.marks[1].points, [ImagePoint(x: -0.5, y: -0.5), ImagePoint(x: 39.5, y: 23.5)], "the edges are inside")
        o.add(ImageMark(kind: .angle, points: [ImagePoint(x: -9, y: -9), ImagePoint(x: 20, y: 99), ImagePoint(x: 99, y: 12)]), on: image)
        XCTAssertEqual(o.marks[2].points, [ImagePoint(x: -0.5, y: -0.5), ImagePoint(x: 20, y: 23.5), ImagePoint(x: 39.5, y: 12)])
        o.move(o.marks[1].id, point: 1, to: ImagePoint(x: 40, y: 24), on: image)    // already at (39.5, 23.5): a no-op
        o.move(o.marks[0].id, point: 0, to: ImagePoint(x: 7, y: 500), on: image)
        XCTAssertEqual(o.marks[0].points[0], ImagePoint(x: 7, y: 23.5))
        XCTAssertEqual(try XCTUnwrap(node(o.marks[0].id, in: o)).parameters["y1"], "23.5")
    }

    /// A profile's width is clamped to 1…25 on `add` and on `setWidth`, and its node holds the clamped width; another kind's
    /// node has no width. Red under: the clamp removed from `add` (the node holds 99, which the reader refuses) or from
    /// `setWidth`; the width recorded for a distance.
    @MainActor func testAProfilesWidthIsClampedAndOnlyAProfileRecordsOne() throws {
        let image = Self.image(), clock = SessionTestClock()
        let o = owner(clock)
        let wide = profile((0, 1), (30, 1), width: 99)
        o.add(wide, on: image)
        XCTAssertEqual(o.marks[0].width, 25)
        XCTAssertEqual(try XCTUnwrap(node(wide.id, in: o)).parameters["width"], "25")
        o.setWidth(wide.id, 3, on: image)
        XCTAssertEqual(try XCTUnwrap(node(wide.id, in: o)).parameters["width"], "3")
        o.setWidth(wide.id, 400, on: image)
        XCTAssertEqual(o.mark(wide.id)?.width, 25)
        XCTAssertEqual(try XCTUnwrap(node(wide.id, in: o)).parameters["width"], "25")
        o.setWidth(wide.id, -4, on: image)
        XCTAssertEqual(try XCTUnwrap(node(wide.id, in: o)).parameters["width"], "1")
        let plain = ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)], width: 7)
        o.add(plain, on: image)
        XCTAssertNil(try XCTUnwrap(node(plain.id, in: o)).parameters["width"], "a distance has no width")
        let revision = o.revision
        o.setWidth(plain.id, 9, on: image)
        XCTAssertEqual(o.revision, revision, "a width on a distance is ignored")
    }

    /// A mark adds one node, from the first mark, with the injected clock's time and the values measured at full precision;
    /// ids run s1, s2 and are never reused; the new mark is selected; each add raises the revision and leaves the file
    /// unsaved. Red under: the clock not used (`recorded` is the real time); no node recorded; `revision` not raised; the
    /// result rounded to the display's text.
    @MainActor func testEveryAddRecordsOneNodeStampedByTheInjectedClock() throws {
        let image = Self.image(), clock = SessionTestClock()
        let o = owner(clock)
        XCTAssertFalse(o.isDirty)
        clock.milliseconds = t0
        let a = distance((0, 0), (6, 5))
        o.add(a, on: image)
        clock.milliseconds = t0 + 7_000
        let b = profile((1, 1), (20, 9), width: 5)
        o.add(b, on: image)
        XCTAssertEqual(o.lineage.nodes.map(\.id), ["s1", "s2"])
        XCTAssertEqual(o.lineage.nodes.map(\.recorded), [t0, t0 + 7_000])
        XCTAssertEqual(o.nodeID(of: a.id), "s1")
        XCTAssertEqual(o.nodeID(of: b.id), "s2")
        XCTAssertEqual(o.selection, b.id)
        XCTAssertEqual(o.revision, 2)
        XCTAssertTrue(o.isDirty)
        let first = try XCTUnwrap(node(a.id, in: o))
        // 6 columns of 0.5 nm and 5 rows of 2 nm: 3 nm and 10 nm, √109 nm; √61 px.
        XCTAssertEqual(Double(try XCTUnwrap(first.results["pixels"])) ?? .nan, 61.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(Double(try XCTUnwrap(first.results["length"])) ?? .nan, 109.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(first.results["unit"], "nm")
        XCTAssertEqual(first.results["scale_x"], "0.5")
        XCTAssertEqual(first.results["unit_y"], "nm")
        let second = try XCTUnwrap(node(b.id, in: o))
        XCTAssertEqual(second.results["samples"], String(try XCTUnwrap(o.profiles[b.id]).samples.count))
        XCTAssertEqual(second.parameters["object"], "ImageList.1")
        XCTAssertEqual(second.parameters["frame"], "0")
    }

    // MARK: Replacing in place (R3)

    /// A move replaces the node IN PLACE: the same id and position, no new node, the new points and results, `recorded` the
    /// clock's new time, `next_id` unchanged, the revision raised. A width change the same. Red under: a move appending a
    /// node; the clock not used on a replace (the old `recorded` stays); the results not recomputed; the revision not raised.
    @MainActor func testAMoveOrAWidthChangeReplacesTheNodeInPlace() throws {
        let image = Self.image(), clock = SessionTestClock()
        let o = owner(clock)
        clock.milliseconds = t0
        let p = profile((0, 1), (30, 1))
        o.add(p, on: image)
        o.add(distance((0, 0), (3, 4)), on: image)
        let before = try XCTUnwrap(node(p.id, in: o))
        clock.milliseconds = t0 + 60_000
        o.move(p.id, point: 1, to: ImagePoint(x: 10, y: 5), on: image)
        XCTAssertEqual(o.lineage.nodes.map(\.id), ["s1", "s2"], "no new node, same position")
        XCTAssertEqual(o.lineage.nextID, 3)
        let moved = try XCTUnwrap(node(p.id, in: o))
        XCTAssertEqual(moved.parameters["x2"], "10.0")
        XCTAssertEqual(moved.parameters["y2"], "5.0")
        XCTAssertEqual(moved.recorded, t0 + 60_000)
        XCTAssertNotEqual(moved.results["pixels"], before.results["pixels"])
        XCTAssertEqual(moved.results["samples"], String(try XCTUnwrap(o.profiles[p.id]).samples.count))
        XCTAssertEqual(o.revision, 3)
        clock.milliseconds = t0 + 90_000
        o.setWidth(p.id, 9, on: image)
        let wider = try XCTUnwrap(node(p.id, in: o))
        XCTAssertEqual(wider.parameters["width"], "9")
        XCTAssertEqual(wider.recorded, t0 + 90_000)
        XCTAssertEqual(o.lineage.nodes.count, 2)
        XCTAssertEqual(o.revision, 4)
    }

    /// A change to nothing records nothing: a move to the point a mark already holds, a move that clamps onto it, a width
    /// already held (or clamped onto it) — the node, the clock and the revision are untouched. Red under: a no-op move
    /// recording (the revision rises and `recorded` changes); the same-value guard of `setWidth` removed.
    @MainActor func testAChangeToNothingRecordsNothing() throws {
        let image = Self.image(), clock = SessionTestClock()
        let o = owner(clock)
        clock.milliseconds = t0
        let p = profile((0, 1), (39.5, 23.5), width: 25)
        o.add(p, on: image)
        let node0 = try XCTUnwrap(node(p.id, in: o))
        let revision = o.revision
        clock.milliseconds = t0 + 1_000
        o.move(p.id, point: 1, to: ImagePoint(x: 39.5, y: 23.5), on: image)       // where it is
        o.move(p.id, point: 1, to: ImagePoint(x: 900, y: 900), on: image)         // clamps onto where it is
        o.setWidth(p.id, 25, on: image)
        o.setWidth(p.id, 99, on: image)                                            // clamps onto 25
        o.move(UUID(), point: 0, to: ImagePoint(x: 1, y: 1), on: image)           // no such mark
        o.move(p.id, point: 5, to: ImagePoint(x: 1, y: 1), on: image)             // no such point
        XCTAssertEqual(try XCTUnwrap(node(p.id, in: o)), node0)
        XCTAssertEqual(o.revision, revision)
    }

    // MARK: Removing

    /// Removing a mark removes its node (deleted, or kept dated while another node cites it); removing all removes the mark
    /// nodes and leaves the other kinds, the clock dating each removal. Red under: `remove` leaving the node, its profile or the selection; `removeAll`
    /// leaving mark nodes or deleting a node of another kind; the removal not dated by the clock; the revision not raised.
    @MainActor func testRemovingAMarkRemovesItsNodeAndRemoveAllLeavesOtherKinds() throws {
        let image = Self.image(), clock = SessionTestClock()
        let a = distance((0, 0), (3, 4)), b = profile((1, 1), (9, 3), width: 3), c = distance((2, 2), (8, 8))
        let object = image.source
        var lineage = SessionLineage()
        try lineage.add(kind: "distance", parameters: SessionMarks.parameters(of: a.sessionMark, object: object), recorded: t0)
        try lineage.add(kind: "profile", parameters: SessionMarks.parameters(of: b.sessionMark, object: object), recorded: t0 + 1)
        try lineage.add(kind: "distance", parameters: SessionMarks.parameters(of: c.sessionMark, object: object), recorded: t0 + 2)
        try lineage.add(kind: "export", parameters: ["file": "a.png"], inputs: [SessionLineage.Edge(step: "s1", role: "image")],
                        recorded: t0 + 3)
        try lineage.add(kind: "fft", parameters: ["size": "256"], recorded: t0 + 4)
        let o = try restoredOwner(lineage, image: image, clock: clock)
        XCTAssertEqual(o.marks.count, 3)
        XCTAssertFalse(o.isDirty, "a restore is the saved state")
        let revision = o.revision
        clock.milliseconds = t0 + 500_000
        o.remove(o.marks[0].id)                     // s1 is cited by the export: kept, dated
        XCTAssertEqual(o.lineage.node(id: "s1")?.removed, t0 + 500_000)
        XCTAssertEqual(o.revision, revision + 1)
        let profileID = o.marks[0].id
        XCTAssertNotNil(o.profiles[profileID])
        o.selection = profileID
        o.remove(profileID)                         // s2 (the profile) is cited by nobody: deleted
        XCTAssertNil(o.lineage.node(id: "s2"))
        XCTAssertNil(o.profiles[profileID], "its profile goes with it")
        XCTAssertNil(o.selection)
        XCTAssertEqual(o.lineage.nodes.map(\.id), ["s1", "s3", "s4", "s5"])
        clock.milliseconds = t0 + 600_000
        o.removeAll()
        XCTAssertTrue(o.marks.isEmpty)
        XCTAssertNil(o.lineage.node(id: "s3"), "the last mark node is gone")
        XCTAssertNotNil(o.lineage.node(id: "s4"), "the export stays")
        XCTAssertNotNil(o.lineage.node(id: "s5"), "an fft node stays")
        XCTAssertEqual(o.lineage.node(id: "s1")?.removed, t0 + 500_000, "a kept node keeps its first date")
        XCTAssertEqual(o.lineage.nextID, 6, "ids are never given back")
        XCTAssertNil(o.selection)
        XCTAssertTrue(o.profiles.isEmpty)
    }

    // MARK: A lineage that cannot take a node

    /// A full lineage (2 000 nodes, removed and other kinds counted) refuses a new mark BY NAME and the mark is not drawn:
    /// nothing is added, no profile is computed, the revision and the selection stand; `recordingRefusal` says so before the
    /// gesture. Every id spent refuses the same way. Red under: a full lineage dropping the node and drawing the mark; the
    /// refusal not returned; the mark drawn though refused; `recordingRefusal` nil.
    @MainActor func testAFullLineageRefusesTheMarkByNameAndDrawsNothing() throws {
        let image = Self.image(), clock = SessionTestClock()
        var full = SessionLineage()
        for i in 0..<SessionLineage.maximumNodes { try full.add(kind: "export", parameters: ["n": String(i)], recorded: t0) }
        let o = try restoredOwner(full, image: image, clock: clock)
        XCTAssertEqual(o.recordingRefusal, .tooManyNodes(2001))
        let revision = o.revision
        XCTAssertEqual(o.add(profile((0, 1), (30, 1)), on: image), .tooManyNodes(2001))
        XCTAssertTrue(o.marks.isEmpty)
        XCTAssertTrue(o.profiles.isEmpty)
        XCTAssertNil(o.selection)
        XCTAssertEqual(o.revision, revision)
        XCTAssertEqual(o.lineage.nodes.count, 2000)

        let spent = try restoredOwner(try SessionLineage.decode(#"{"next_id":1000000,"nodes":[],"version":1}"#), image: image,
                                      clock: clock)
        XCTAssertEqual(spent.recordingRefusal, .idsExhausted)
        XCTAssertEqual(spent.add(distance((0, 0), (3, 4)), on: image), .idsExhausted)
        XCTAssertTrue(spent.marks.isEmpty)

        let fresh = owner(clock)
        XCTAssertNil(fresh.recordingRefusal)
        XCTAssertNil(fresh.add(distance((0, 0), (3, 4)), on: image))
    }

    // MARK: The byte budget

    /// The saved text of `owner` for `identity`: the request's total (what the writer holds to 60,000).
    @MainActor private func savedBytes(_ owner: ImageMeasurements, _ identity: SessionSourceIdentity) throws -> Int {
        let request = try owner.saveRequest(opened: identity)
        return SessionSidecarFile.totalTextBytes(sourceBytes: request.source.utf8.count, lineageBytes: request.lineage.utf8.count)
    }

    /// A lineage of one other-kind node padded so that the saved text (for `identity`) leaves exactly `room` bytes under the
    /// 60,000-byte budget.
    private func lineage(leavingRoom room: Int, for identity: SessionSourceIdentity, kind: String = "export",
                         removedMark: Bool = false) throws -> SessionLineage {
        func build(_ pad: Int) throws -> SessionLineage {
            var lineage = SessionLineage()
            if removedMark {
                var parameters = SessionMarks.parameters(of: distance((0, 0), (3, 4)).sessionMark, object: identity.object)
                parameters["note"] = String(repeating: "r", count: pad)
                try lineage.add(kind: "distance", parameters: parameters, recorded: t0)
                try lineage.add(kind: "export", parameters: ["file": "a.png"],
                                inputs: [SessionLineage.Edge(step: "s1", role: "image")], recorded: t0 + 1)
                lineage.remove(id: "s1", at: t0 + 2)
            } else {
                try lineage.add(kind: kind, parameters: ["pad": String(repeating: "p", count: pad)], recorded: t0)
            }
            return lineage
        }
        let base = try build(0)
        let total = 2 + (try identity.jsonString().utf8.count) + (try base.jsonString().utf8.count)
        let pad = 60_000 - room - total
        XCTAssertGreaterThanOrEqual(pad, 0)
        let made = try build(pad)
        XCTAssertEqual(2 + (try identity.jsonString().utf8.count) + (try made.jsonString().utf8.count), 60_000 - room)
        return made
    }

    /// The owner refuses, BY NAME, the mark whose node would take the saved text past 60,000 bytes, and the mark is not drawn:
    /// marks are added until the first refusal, which carries the total the record would have had (computed here from the
    /// lineage plus the refused node) and the limit; every accepted state saves within the budget; the refused mark leaves
    /// the marks, nodes, revision and selection as they were. Red under: the owner's byte check removed (the record grows past
    /// the cap and the save is refused later); the check on the count alone; the refused mark still drawn; the check `>=`
    /// (a record of exactly 60,000 bytes is refused); the refusal naming the old total.
    @MainActor func testTheByteBudgetRefusesTheMarkThatWouldPassItAndDrawsNothing() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let o = owner(clock)
        o.noteOpened(identity)
        clock.milliseconds = t0
        var accepted = 0
        var refused: (ImageMark, SessionLineage.Refusal)?
        for i in 0..<400 {
            let mark = profile((1.5, 2.0 + Double(i % 20) * 0.37), (30.25 - Double(i % 7) * 0.31, 19.75), width: 7)
            if let refusal = o.add(mark, on: image) { refused = (mark, refusal); break }
            accepted += 1
            XCTAssertLessThanOrEqual(try savedBytes(o, identity), 60_000, "after \(accepted) marks")
        }
        let (mark, refusal) = try XCTUnwrap(refused)
        XCTAssertTrue((100..<250).contains(accepted), "about 140 profile marks fit, got \(accepted)")
        // the total the record would have had, independently: the lineage so far plus the refused mark's node
        var candidate = o.lineage
        let clamped = ImageMark(id: mark.id, kind: mark.kind, points: mark.points, width: mark.width)
        let profileSamples = LineProfile.sample(image, from: clamped.points[0], to: clamped.points[1], width: clamped.width).samples.count
        try candidate.add(kind: "profile", parameters: SessionMarks.parameters(of: clamped.sessionMark, object: image.source),
                          results: SessionMarks.results(of: clamped.sessionMark, x: image.x, y: image.y, samples: profileSamples),
                          recorded: t0)
        let would = 2 + (try identity.jsonString().utf8.count) + (try candidate.jsonString().utf8.count)
        XCTAssertGreaterThan(would, 60_000)
        XCTAssertEqual(refusal, .tooLargeToSave(bytes: would, limit: 60_000))
        XCTAssertEqual(o.marks.count, accepted)
        XCTAssertNil(o.mark(mark.id))
        XCTAssertNil(o.profiles[mark.id])
        XCTAssertEqual(o.lineage.nodes.count, accepted)
        XCTAssertEqual(o.revision, accepted)
        XCTAssertEqual(o.selection, o.marks.last?.id)
        XCTAssertTrue(refusal.reason.contains("remove some marks"), refusal.reason)
    }

    /// `recordingRefusal` says so BEFORE a gesture: when the room left under the budget is less than the smallest node a mark
    /// can record it names the budget; with exactly that much room it is nil, and a mark that fits is then recorded, to a
    /// record of exactly 60,000 bytes. Other kinds' nodes count (an `export` that already holds 59,000 bytes), and so do a
    /// removed mark's, kept for its citer. The 2 000-node limit stays first (`mintRefusal`), also when the bytes are over too.
    /// Red under: `recordingRefusal` as `mintRefusal` alone; the smallest node taken as 0 (the boundary moves); other kinds
    /// or removed nodes left out of the count; the count limit judged after the bytes.
    @MainActor func testRecordingRefusalSaysSoBeforeAGestureAndCountsEveryNode() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let smallest = SessionMarks.smallestNodeBytes
        XCTAssertGreaterThan(smallest, 150)
        XCTAssertLessThan(smallest, 400)
        for (label, kind, removedMark) in [("other kind", "export", false), ("a removed mark kept for its citer", "export", true)] {
            let tight = try restoredOwner(try lineage(leavingRoom: smallest - 1, for: identity, kind: kind, removedMark: removedMark),
                                          image: image, clock: clock)
            XCTAssertEqual(tight.recordingRefusal, .tooLargeToSave(bytes: 60_001, limit: 60_000), label)
            XCTAssertEqual(tight.add(distance((0, 0), (3, 4)), on: image).map { if case .tooLargeToSave = $0 { true } else { false } }, true, label)
            XCTAssertTrue(tight.marks.isEmpty, label)
            let roomy = try restoredOwner(try lineage(leavingRoom: smallest, for: identity, kind: kind, removedMark: removedMark),
                                          image: image, clock: clock)
            XCTAssertNil(roomy.recordingRefusal, "\(label): room for the smallest node")
        }
        // a record that is exactly at the budget is made (the real node is larger than the smallest, so give it the room it needs,
        // measured on a roomy copy of the same lineage)
        let roomy = try restoredOwner(try lineage(leavingRoom: 2_000, for: identity), image: image, clock: clock)
        XCTAssertNil(roomy.add(distance((0, 0), (3, 4)), on: image))
        let nodeBytes = try savedBytes(roomy, identity) - (60_000 - 2_000)
        XCTAssertGreaterThan(nodeBytes, smallest)
        let exact = try restoredOwner(try lineage(leavingRoom: nodeBytes, for: identity), image: image, clock: clock)
        XCTAssertNil(exact.add(distance((0, 0), (3, 4)), on: image), "a record of exactly 60,000 bytes is made")
        XCTAssertEqual(try savedBytes(exact, identity), 60_000)
        let over = try restoredOwner(try lineage(leavingRoom: nodeBytes - 1, for: identity), image: image, clock: clock)
        XCTAssertEqual(over.add(distance((0, 0), (3, 4)), on: image), .tooLargeToSave(bytes: 60_001, limit: 60_000))
        // the count limit first
        var crowded = SessionLineage()
        for i in 0..<SessionLineage.maximumNodes { try crowded.add(kind: "export", parameters: ["n": String(i)], recorded: t0) }
        XCTAssertGreaterThan(try crowded.jsonString().utf8.count, 60_000, "also over the bytes")
        let full = try restoredOwner(crowded, image: image, clock: clock)
        XCTAssertEqual(full.recordingRefusal, .tooManyNodes(2001))
        XCTAssertEqual(full.add(distance((0, 0), (3, 4)), on: image), .tooManyNodes(2001))
        // and 100 nodes of 600 bytes are over the bytes long before they are over the count
        var heavy = SessionLineage()
        for i in 0..<100 { try heavy.add(kind: "export", parameters: ["pad": String(repeating: "h", count: 600), "n": String(i)], recorded: t0) }
        let few = try restoredOwner(heavy, image: image, clock: clock)
        XCTAssertNil(few.lineage.mintRefusal, "100 nodes are far under the count limit")
        XCTAssertEqual(few.recordingRefusal.map { if case .tooLargeToSave = $0 { true } else { false } }, true)
    }

    /// A change of a mark that would take the record past the budget is not made — the node's new numbers are longer — and the
    /// mark stays where it was, the node, the profile and the revision untouched; a change that keeps the record within it is
    /// (a replace rewrites the node's parameters, so the padding here is another node's). Red under: the budget not checked on
    /// a replace (the owner then holds a record the writer refuses).
    @MainActor func testAMoveThatWouldGrowTheRecordPastTheBudgetIsNotMade() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let mark = distance((1, 1), (3, 4)).sessionMark
        func lineage(_ pad: Int) throws -> SessionLineage {
            var l = SessionLineage()
            try l.add(kind: "distance", parameters: SessionMarks.parameters(of: mark, object: image.source),
                      results: SessionMarks.results(of: mark, x: image.x, y: image.y, samples: nil), recorded: t0)
            try l.add(kind: "export", parameters: ["pad": String(repeating: "p", count: pad)], recorded: t0)
            return l
        }
        let sourceBytes = try identity.jsonString().utf8.count
        let pad = 60_000 - (2 + sourceBytes + (try lineage(0).jsonString().utf8.count))
        let start = try lineage(pad)
        XCTAssertEqual(2 + sourceBytes + (try start.jsonString().utf8.count), 60_000)
        let o = try restoredOwner(start, image: image, clock: clock)
        XCTAssertEqual(try savedBytes(o, identity), 60_000)
        let id = o.marks[0].id
        let node0 = try XCTUnwrap(node(id, in: o))
        o.move(id, point: 1, to: ImagePoint(x: 3.1234567890123, y: 4), on: image)              // longer numbers: refused
        XCTAssertEqual(o.marks[0].points[1], ImagePoint(x: 3, y: 4))
        XCTAssertEqual(try XCTUnwrap(node(id, in: o)), node0)
        XCTAssertEqual(o.revision, 0)
        o.setWidth(id, 9, on: image)                                                            // a distance has no width: nothing
        o.move(id, point: 1, to: ImagePoint(x: 3, y: 1), on: image)                             // shorter numbers: made
        XCTAssertEqual(o.marks[0].points[1], ImagePoint(x: 3, y: 1))
        XCTAssertEqual(o.revision, 1)
        XCTAssertLessThanOrEqual(try savedBytes(o, identity), 60_000)
    }

    // MARK: A point that is not a place

    /// A mark with a point that is not a finite number is refused by name and drawn nowhere — NaN would pass the clamp
    /// (`min(max(nan, -0.5), …)` is nan) and be recorded as "nan", which every later save would refuse — and a drag to such a
    /// point is ignored. Red under: the check removed from `add` (the mark is held and recorded as nan); from `move`.
    @MainActor func testANonFinitePointIsRefusedByAddAndIgnoredByMove() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let o = owner(clock)
        for point in [ImagePoint(x: .nan, y: 3), ImagePoint(x: 3, y: .nan), ImagePoint(x: .infinity, y: 3), ImagePoint(x: 3, y: -.infinity)] {
            XCTAssertEqual(o.add(ImageMark(kind: .distance, points: [ImagePoint(x: 1, y: 1), point]), on: image), .notFinite)
            XCTAssertEqual(o.add(ImageMark(kind: .angle, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 2, y: 2), point]), on: image), .notFinite)
        }
        XCTAssertTrue(o.marks.isEmpty)
        XCTAssertTrue(o.lineage.nodes.isEmpty)
        XCTAssertEqual(o.revision, 0)
        let m = distance((1, 1), (5, 5))
        XCTAssertNil(o.add(m, on: image))
        for point in [ImagePoint(x: .nan, y: 3), ImagePoint(x: 3, y: .infinity)] {
            o.move(m.id, point: 1, to: point, on: image)
        }
        XCTAssertEqual(o.marks[0].points, [ImagePoint(x: 1, y: 1), ImagePoint(x: 5, y: 5)])
        XCTAssertEqual(o.revision, 1)
        XCTAssertNoThrow(try o.saveRequest(opened: identity), "the record is still one a save accepts")
        XCTAssertEqual(SessionLineage.Refusal.notFinite.reason, "a point of the mark is not a finite number")
    }

    /// A read-only lineage (a newer version's) is drawn and not recorded: the marks work, no node is made, the file is never
    /// dirty, `recordingRefusal` names the version, and saving is refused by name — `savingRefusal` before a try and
    /// `saveRequest` when tried. Red under: a mark on a read-only lineage refused (it is not drawn); the read-only check
    /// removed from `savingRefusal` or `saveRequest` (the lineage's own writer then refuses, as another case).
    @MainActor func testAReadOnlyLineageDrawsMarksRecordsNothingAndRefusesToSave() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let future = SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try identity.jsonString(),
                                                 lineage: #"{"nodes":{"s1":[1,2,3]},"next_id":4,"version":2}"#)
        let result = try XCTUnwrap(restored(future, opened: identity, image: image))
        let o = owner(clock)
        try o.restore(result, opened: identity, on: image)
        XCTAssertTrue(o.lineage.isReadOnly)
        XCTAssertEqual(o.recordingRefusal, .unsupportedVersion(2))
        XCTAssertEqual(o.savingRefusal, .readOnly(2))
        let m = distance((0, 0), (3, 4))
        XCTAssertNil(o.add(m, on: image), "drawn, not recorded: no refusal")
        XCTAssertEqual(o.marks.count, 1)
        XCTAssertNil(o.nodeID(of: m.id))
        XCTAssertTrue(o.lineage.nodes.isEmpty)
        o.move(m.id, point: 1, to: ImagePoint(x: 9, y: 9), on: image)
        XCTAssertEqual(o.marks[0].points[1], ImagePoint(x: 9, y: 9))
        XCTAssertFalse(o.isDirty)
        XCTAssertEqual(o.revision, 0)
        XCTAssertThrowsError(try o.saveRequest(opened: identity)) { XCTAssertEqual($0 as? SessionSave.Refusal, .readOnly(2)) }
        o.remove(m.id)
        XCTAssertTrue(o.marks.isEmpty)
    }

    // MARK: Saving

    /// A refused sidecar blocks saving until the user chooses to replace it: `savingRefusal` names it (with the sentence)
    /// and `saveRequest` throws it; after `replaceRefusedSidecar` the request is made with `replacing`, and a save clears
    /// the choice. Red under: the refusal ignored by `saveRequest`; `replaceRefusedSidecar` not honoured; the choice kept
    /// after a save.
    @MainActor func testASaveAfterARefusedSidecarWaitsForTheChoiceToReplaceIt() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let o = owner(clock)
        o.add(distance((0, 0), (3, 4)), on: image)
        XCTAssertNil(o.savingRefusal)
        o.sidecarRefused("it is not a macTEM session file")
        XCTAssertEqual(o.savingRefusal, .sidecarRefused("it is not a macTEM session file"))
        XCTAssertThrowsError(try o.saveRequest(opened: identity)) {
            XCTAssertEqual($0 as? SessionSave.Refusal, .sidecarRefused("it is not a macTEM session file"))
        }
        XCTAssertEqual(o.sidecar, .refused("it is not a macTEM session file"))
        o.replaceRefusedSidecar()
        XCTAssertNil(o.savingRefusal)
        let request = try o.saveRequest(opened: identity)
        XCTAssertTrue(request.replacing)
        o.didSave(request, opened: identity)
        XCTAssertFalse(try o.saveRequest(opened: identity).replacing, "the choice was for one save")
    }

    /// A save request is the opened image's identity and the lineage as canonical text, the owner's revision when it was
    /// taken, and what the file on disk should hold (nothing before a first save or a restore). It is the pure part's: the
    /// marks are checked with the restore's own checks, so a mark of this image is saved and one against another image's
    /// shape is refused by name. Red under: the identity or the lineage of another state; the revision not carried; the
    /// expected lineage not carried after a restore.
    @MainActor func testTheSaveRequestIsTheIdentityAndTheLineageAtTheRevision() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let o = owner(clock)
        o.add(distance((0, 0), (6, 5)), on: image)
        o.add(angle(), on: image)
        let request = try o.saveRequest(opened: identity)
        XCTAssertEqual(request.source, try identity.jsonString())
        XCTAssertEqual(request.lineage, try o.lineage.jsonString())
        XCTAssertEqual(request.revision, 2)
        XCTAssertNil(request.expectedOnDisk)
        XCTAssertNil(request.expectedSource)
        XCTAssertFalse(request.replacing)
        // The image the save describes is another shape: the nodes are outside it, refused by name.
        let small = SessionSourceIdentity(fileName: "scan.dm4", byteSize: 1, object: image.source, width: 8, height: 6,
                                          pixelSHA256: identity.pixelSHA256)
        XCTAssertThrowsError(try o.saveRequest(opened: small)) {
            guard case .mark(.outsideImage)? = $0 as? SessionSave.Refusal else { return XCTFail("\($0)") }
        }
        // After a restore the file on disk should hold the lineage as it was read.
        let back = try restoredOwner(o.lineage, image: image, clock: clock)
        XCTAssertEqual(try back.saveRequest(opened: identity).expectedOnDisk, request.lineage)
        // And the source attribute as it was read (red under: the changed-on-disk check fed the lineage only).
        XCTAssertEqual(try back.saveRequest(opened: identity).expectedSource, request.source)
    }

    /// `didSave` marks the REQUEST's revision saved: a mark added while the write ran leaves the file unsaved. It sets the
    /// sidecar to `saved`, answers the notes, and the next request expects the lineage just written. Red under: `didSave`
    /// taking the owner's current revision (the edit during the write is lost); the notes kept; the expected lineage not
    /// updated; the sidecar state not set.
    @MainActor func testDidSaveMarksTheRequestsRevisionAndAnEditDuringTheWriteLeavesItDirty() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let o = owner(clock)
        o.add(distance((0, 0), (6, 5)), on: image)
        o.noteOpened(identity)
        o.noteOpened(SessionSourceIdentity(fileName: identity.fileName, byteSize: 1, object: identity.object, width: identity.width,
                                           height: identity.height, pixelSHA256: String(repeating: "0", count: 64)))
        XCTAssertEqual(o.notes, [.pixelsDiffer])
        let request = try o.saveRequest(opened: identity)
        o.add(distance((1, 1), (9, 9)), on: image)                       // while the write runs
        o.didSave(request, opened: identity)
        XCTAssertEqual(o.savedRevision, 1)
        XCTAssertTrue(o.isDirty)
        XCTAssertEqual(o.sidecar, .saved)
        XCTAssertTrue(o.notes.isEmpty)
        let next = try o.saveRequest(opened: identity)
        XCTAssertEqual(next.expectedOnDisk, request.lineage)
        XCTAssertEqual(next.expectedSource, request.source)
        o.didSave(next, opened: identity)
        XCTAssertFalse(o.isDirty)
    }

    /// `noteOpened`: the first identity read is the image the marks are drawn on; a later read with other pixels, while there
    /// are marks, notes that they differ, once; the same pixels, or no marks, note nothing. Red under: a note on equal
    /// pixels; on no marks; twice.
    @MainActor func testARereadWithOtherPixelsNotesItOnceAndOnlyWhileThereAreMarks() throws {
        let image = Self.image(), clock = SessionTestClock()
        let a = identity(of: image), b = identity(of: Self.image(shift: 1))
        XCTAssertNotEqual(a.pixelSHA256, b.pixelSHA256)
        let empty = owner(clock)
        empty.noteOpened(a)
        empty.noteOpened(b)
        XCTAssertTrue(empty.notes.isEmpty, "no marks, nothing to differ")
        let o = owner(clock)
        o.noteOpened(a)
        o.add(distance((0, 0), (3, 4)), on: image)
        o.noteOpened(a)
        XCTAssertTrue(o.notes.isEmpty)
        o.noteOpened(b)
        o.noteOpened(b)
        XCTAssertEqual(o.notes, [.pixelsDiffer])
    }

    /// A save after a re-read with other pixels is refused, so marks are never written over pixels they were not drawn on;
    /// the user's Save Anyway lets it through once, and that save makes the new pixels the ones the marks are drawn on. The
    /// same pixels, or nothing drawn, save as before. Red under: `saveRequest` not comparing the opened identity with the
    /// one the marks were drawn on; Save Anyway not offered for this refusal.
    @MainActor func testASaveAfterARereadWithOtherPixelsIsRefusedUntilSaveAnyway() throws {
        let image = Self.image(), clock = SessionTestClock()
        let a = identity(of: image), b = identity(of: Self.image(shift: 1))
        let empty = owner(clock)
        empty.noteOpened(a)
        XCTAssertNoThrow(try empty.saveRequest(opened: b), "nothing drawn, nothing to protect")
        let o = owner(clock)
        o.noteOpened(a)
        o.add(distance((0, 0), (3, 4)), on: image)
        XCTAssertNoThrow(try o.saveRequest(opened: a))
        o.noteOpened(b)
        XCTAssertThrowsError(try o.saveRequest(opened: b)) { XCTAssertEqual($0 as? SessionSave.Refusal, .pixelsChanged) }
        XCTAssertTrue(SessionSaving.Failure.refused(name: "scan.mactem.h5", .pixelsChanged).offersSaveAnyway)
        XCTAssertFalse(SessionSaving.Failure.refused(name: "scan.mactem.h5", .changedOnDisk).offersSaveAnyway)
        o.acceptNewPixels(b)
        let request = try o.saveRequest(opened: b)
        o.didSave(request, opened: b)
        o.add(distance((1, 1), (4, 5)), on: image)
        XCTAssertNoThrow(try o.saveRequest(opened: b), "the save made b the image the marks are drawn on")
    }

    /// Save Anyway takes the pixels the user saw, not every later image: accepted for b, a save that never happened leaves
    /// a re-read with yet other pixels (c) refused again. Red under: the acceptance kept as a flag that only a save clears.
    @MainActor func testSaveAnywayAcceptsOnlyThePixelsTheUserSaw() throws {
        let image = Self.image(), clock = SessionTestClock()
        let a = identity(of: image), b = identity(of: Self.image(shift: 1)), c = identity(of: Self.image(shift: 2))
        let o = owner(clock)
        o.noteOpened(a)
        o.add(distance((0, 0), (3, 4)), on: image)
        o.noteOpened(b)
        o.acceptNewPixels(b)
        XCTAssertNoThrow(try o.saveRequest(opened: b))
        o.noteOpened(c)
        XCTAssertThrowsError(try o.saveRequest(opened: c)) { XCTAssertEqual($0 as? SessionSave.Refusal, .pixelsChanged) }
    }

    /// Marks first drawn after a re-read are drawn on the image re-read: a file opened, left without a mark, read again
    /// with other pixels and then marked saves without a refusal. Red under: only the first read setting the image the
    /// marks are drawn on.
    @MainActor func testMarksFirstDrawnAfterARereadSaveWithoutARefusal() throws {
        let image = Self.image(), clock = SessionTestClock()
        let a = identity(of: image), b = identity(of: Self.image(shift: 1))
        let o = owner(clock)
        o.noteOpened(a)
        o.noteOpened(b)
        o.add(distance((0, 0), (3, 4)), on: image)
        XCTAssertNoThrow(try o.saveRequest(opened: b))
    }

    // MARK: Restoring

    /// P1, a restore equals the save: for a lineage this build wrote — marks of the three kinds, a removed node kept for an
    /// export, another kind, a profile at width 5 — restored and saved again with no edit, the lineage text is byte for byte
    /// the same (ids, `next_id`, `recorded`, removed dates, the other kinds); each mark's kind, points (bit-exact), width and
    /// order, and its node id, equal the saved ones; each profile is measured again on the file's own pixels and equals the
    /// one before, bit for bit. The restored file is not dirty, the sidecar `restored`, no mark selected. Red under: the
    /// restore re-stamping `recorded` or replacing a node; a node of another kind dropped; the removed node drawn; ids
    /// re-minted or `next_id` re-derived; x and y swapped, the vertex not point 2, the width not restored (SessionMarks);
    /// profiles not measured again at restore.
    @MainActor func testARestoreEqualsTheSave() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        let o = owner(clock)
        clock.milliseconds = t0
        o.add(distance((2.5, 1.25), (30.75, 17.5)), on: image)
        clock.milliseconds = t0 + 1_000
        o.add(angle(), on: image)
        clock.milliseconds = t0 + 2_000
        o.add(profile((1.5, 2), (33.25, 20.75), width: 5), on: image)
        clock.milliseconds = t0 + 3_000
        o.add(distance((0, 0), (1, 1)), on: image)
        // Another kind and an export citing the first mark, written the way a later build would.
        var lineage = o.lineage
        try lineage.add(kind: "fft", parameters: ["size": "256"], results: ["peak": "3.5"], recorded: t0 + 4_000)
        try lineage.add(kind: "export", parameters: ["file": "a.png"], inputs: [SessionLineage.Edge(step: "s1", role: "image")],
                        recorded: t0 + 5_000)
        lineage.remove(id: "s1", at: t0 + 6_000)                         // kept, dated, for the export
        let text = try lineage.jsonString()

        let back = try restoredOwner(lineage, image: image, clock: clock)
        XCTAssertEqual(try back.lineage.jsonString(), text)
        XCTAssertEqual(try back.saveRequest(opened: identity).lineage, text, "a restore saved again with no edit: the same bytes")
        XCTAssertEqual(back.lineage.nextID, lineage.nextID)
        XCTAssertEqual(back.marks.map(\.sessionMark), o.marks.dropFirst().map(\.sessionMark),
                       "s1 is removed (kept for the export): not drawn; the other three are, in order")
        XCTAssertEqual(back.marks.map { back.nodeID(of: $0.id) }, ["s2", "s3", "s4"])
        XCTAssertEqual(back.marks[1].points, o.marks[2].points)
        XCTAssertEqual(back.marks[0].points[1], ImagePoint(x: 4, y: 12.75), "an angle's vertex is point 2")
        XCTAssertEqual(back.marks[1].width, 5)
        let profileBefore = try XCTUnwrap(o.profiles[o.marks[2].id])
        let profileAfter = try XCTUnwrap(back.profiles[back.marks[1].id])
        XCTAssertEqual(profileAfter, profileBefore, "measured again on the file's pixels, equal bit for bit")
        XCTAssertFalse(back.isDirty)
        XCTAssertEqual(back.sidecar, .restored)
        XCTAssertNil(back.selection)
        XCTAssertTrue(back.notes.isEmpty)
        XCTAssertNotNil(back.lineage.node(id: "s5"), "a node of another kind is kept")
        XCTAssertEqual(back.lineage.node(id: "s1")?.removed, t0 + 6_000)
    }

    /// A restore measures each profile on the pixels of the image it is adopted on — the file's own, never the saved
    /// numbers — and a re-read (`refresh`) measures them again and touches no node. Red under: the profile taken from the
    /// saved record or not computed at restore; `refresh` rewriting a node.
    @MainActor func testARestoredProfileIsMeasuredOnTheOpenedPixelsAndARefreshTouchesNoNode() throws {
        let saved = Self.image(), changed = Self.image(shift: 3), clock = SessionTestClock()
        let o = owner(clock)
        clock.milliseconds = t0
        let p = profile((0, 2), (30, 9), width: 3)
        o.add(p, on: saved)
        // The same shape with other pixels: restored on `changed`, flagged, measured on `changed`'s pixels.
        let storedIdentity = identity(of: saved), openedIdentity = identity(of: changed)
        let result = try XCTUnwrap(restored(try contents(storedIdentity, o.lineage), opened: openedIdentity, image: changed))
        let target = owner(clock)
        try target.restore(result, opened: openedIdentity, on: changed)
        let measured = try XCTUnwrap(target.profiles[target.marks[0].id])
        XCTAssertEqual(measured, LineProfile.sample(changed, from: p.points[0], to: p.points[1], width: 3))
        XCTAssertNotEqual(measured.samples, try XCTUnwrap(o.profiles[p.id]).samples)
        XCTAssertEqual(target.notes, [.pixelsDiffer])
        let nodes = target.lineage.nodes
        clock.milliseconds = t0 + 99_000
        target.refresh(on: saved)
        XCTAssertEqual(target.lineage.nodes, nodes, "refresh rewrites no node")
        XCTAssertEqual(target.profiles[target.marks[0].id], LineProfile.sample(saved, from: p.points[0], to: p.points[1], width: 3))
        XCTAssertEqual(target.revision, 0)
    }

    /// P3, the notes a restore raises: other pixels (`pixelsDiffer`), the same pixels under another name (`renamed`), and a
    /// mark measured with other scales or units than the opened axes (`calibrationDiffers`), each alone and the verdict's
    /// before the calibration's; a calibration that matches raises none. Red under: the verdict skipped (no note); the
    /// calibration note skipped; `scale_x` and `scale_y` swapped or `unit` kept for mixed units (SessionMarks); the notes
    /// not cleared by a save.
    @MainActor func testARestoreRaisesTheNotesTheVerdictAndTheCalibrationCallFor() throws {
        let clock = SessionTestClock()
        let drawn = Self.image()
        let o = owner(clock)
        o.add(distance((0, 0), (6, 5)), on: drawn)
        let stored = identity(of: drawn)
        func adopt(opened image: CalibratedImage) throws -> ImageMeasurements {
            let opened = identity(of: image)
            let result = try XCTUnwrap(restored(try contents(stored, o.lineage), opened: opened, image: image))
            let target = owner(clock)
            try target.restore(result, opened: opened, on: image)
            return target
        }
        XCTAssertTrue(try adopt(opened: drawn).notes.isEmpty)
        XCTAssertEqual(try adopt(opened: Self.image(shift: 1)).notes, [.pixelsDiffer])
        XCTAssertEqual(try adopt(opened: Self.image(fileName: "renamed.dm4")).notes, [.renamed(from: "scan.dm4")])
        let rescaled = Self.image(x: AxisCalibration(scale: 0.25, unit: "nm", origin: 0))
        XCTAssertEqual(try adopt(opened: rescaled).notes, [.calibrationDiffers])
        let swapped = Self.image(x: AxisCalibration(scale: 2.0, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0))
        XCTAssertEqual(try adopt(opened: swapped).notes, [.calibrationDiffers], "the scales are each axis's own")
        let uncalibrated = Self.image(x: nil, y: nil)
        XCTAssertEqual(try adopt(opened: uncalibrated).notes, [.calibrationDiffers])
        let bothDiffer = Self.image(shift: 2, x: AxisCalibration(scale: 0.25, unit: "nm", origin: 0))
        XCTAssertEqual(try adopt(opened: bothDiffer).notes, [.pixelsDiffer, .calibrationDiffers], "the verdict's note first")
        XCTAssertEqual(ImageMeasurements.Note.calibrationDiffers.sentence, "The image's calibration differs from when the marks were measured.")
        XCTAssertEqual(ImageMeasurements.Note.pixelsDiffer.sentence, "The image differs from when the marks were drawn.")
        XCTAssertEqual(ImageMeasurements.Note.renamed(from: "scan.dm4").sentence, "The marks were saved for \u{201C}scan.dm4\u{201D}.")
    }

    /// A restore is adopted only into an owner that holds no mark and no node, and refuses otherwise changing NOTHING: an
    /// owner with a mark, one whose only mark was removed (ids are never given back, `next_id` is past 1), one already
    /// restored. Red under: the guard removed (the unsaved marks are replaced); the guard on marks only.
    @MainActor func testARestoreIsAdoptedOnlyIntoAnEmptyOwner() throws {
        let image = Self.image(), clock = SessionTestClock()
        let identity = identity(of: image)
        var lineage = SessionLineage()
        try lineage.add(kind: "distance", parameters: SessionMarks.parameters(of: distance((0, 0), (3, 4)).sessionMark, object: image.source),
                        recorded: t0)
        let result = try XCTUnwrap(restored(try contents(identity, lineage), opened: identity, image: image))

        func refuses(_ o: ImageMeasurements, _ what: String) {
            let marks = o.marks, nodes = o.lineage.nodes, next = o.lineage.nextID, sidecar = o.sidecar, revision = o.revision
            XCTAssertThrowsError(try o.restore(result, opened: identity, on: image), what) {
                XCTAssertEqual($0 as? ImageMeasurements.RestoreRefusal, .notEmpty, what)
            }
            XCTAssertEqual(o.marks, marks, what)
            XCTAssertEqual(o.lineage.nodes, nodes, what)
            XCTAssertEqual(o.lineage.nextID, next, what)
            XCTAssertEqual(o.sidecar, sidecar, what)
            XCTAssertEqual(o.revision, revision, what)
        }
        let withMark = owner(clock)
        withMark.add(distance((0, 0), (1, 1)), on: image)
        refuses(withMark, "a mark")
        let removed = owner(clock)
        let m = distance((0, 0), (1, 1))
        removed.add(m, on: image)
        removed.remove(m.id)
        XCTAssertTrue(removed.marks.isEmpty)
        XCTAssertTrue(removed.lineage.nodes.isEmpty)
        refuses(removed, "a removed mark (ids are spent)")
        let again = owner(clock)
        try again.restore(result, opened: identity, on: image)
        refuses(again, "already restored")
        let fresh = owner(clock)
        XCTAssertNoThrow(try fresh.restore(result, opened: identity, on: image))
        XCTAssertEqual(fresh.marks.count, 1)
    }

    /// `ImageMark`'s two conversions are inverses for the three kinds: a mark to the sidecar's and back keeps the kind, the
    /// points and a profile's width (a new id). Red under: the kinds mapped to one another; the width dropped.
    @MainActor func testAMarkSurvivesTheConversionToTheSidecarsMarkAndBack() {
        for mark in [distance((1, 2), (3, 4)), angle(), profile((1, 2), (30, 20), width: 7)] {
            let back = ImageMark(mark.sessionMark)
            XCTAssertEqual(back.kind, mark.kind)
            XCTAssertEqual(back.points, mark.points)
            XCTAssertEqual(back.width, mark.kind == .profile ? mark.width : 1)
            XCTAssertNotEqual(back.id, mark.id)
        }
        XCTAssertEqual(ImageMeasurements.maximumWidth, 25)
    }
}
