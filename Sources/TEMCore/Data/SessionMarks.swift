//
//  SessionMarks.swift
//  Role: the Image room's marks as the session sidecar records them (archive: roadmap-registrations-2026-10-15.md V1-2 slice B, ADR 020 D2): a mark to its
//        lineage node and back, the checks a mark node passes (the reader's, and the writer's before a save), the restore
//        — a read sidecar to the marks it restores, or one named refusal, decided whole before anything is adopted — and
//        the save's request and its write. Pure but for `SessionSave.write`, which goes through SessionSidecarFile. No
//        SwiftUI, no state: the live lineage of a file is TEMSession's `ImageMeasurements`.
//
//  THE NODE of a mark (kind `distance`, `angle` or `profile`). Coordinates are image pixel coordinates: x the column, y
//  the row, a pixel's centre at integers, the image from −0.5 to W − 0.5 and −0.5 to H − 0.5.
//    parameters  x1 y1 x2 y2 (an angle also x3 y3; its VERTEX is point 2), a profile's `width` (1…25), `object` (the
//                opened image's `CalibratedImage.source`), `frame` ("0": the frame the reader opened; V1-3c-ii's seam)
//    results     what was measured when the mark was made or last changed, in the file's own units at full precision
//                (never the display's rounded text): distance `pixels`, and `length` + `unit` when both axes are
//                calibrated in one unit; angle `degrees` (absent for a zero-length arm) and `plane` (`physical` |
//                `pixel`); profile `samples` (the count; the intensities are not stored), `pixels`, `length` + `unit`;
//                and `scale_x`, `scale_y`, `unit_x`, `unit_y` (absent for an uncalibrated axis)
//  Every number a `SessionLineage.coordinateString`. Nodes are a VERBATIM record: a restore draws the marks from the
//  parameters and measures them again on the pixels; it never rewrites a node, and nothing reads `results` back but the
//  calibration note (a node's recorded scales against the opened axes').
//
//  THE CHECKS, each a named refusal naming the node: a required key absent (the points of the kind, a profile's width,
//  `object`, `frame`); a coordinate outside the grammar `-?digits(.digits)?(e[+-]?digits)?` (what Swift's shortest
//  round-trip description writes, and Python's repr; not hex, not ".5", not "+1") or not finite; a point outside the image
//  (inclusive bounds: a zero-length mark is a mark); a width that is not plain digits 1…25. Extra keys are kept and not
//  read. A live mark node of another `object` or `frame` is not this image's to draw: kept in the lineage, not drawn, as
//  removed nodes and other kinds are.
//

import ImagoCore
import Foundation

/// One mark as the sidecar records it: the value TEMCore and TEMSession share (TEMSession's `ImageMark` adds an id).
package nonisolated struct SessionMark: Sendable, Equatable {
    package enum Kind: String, Sendable, Equatable, CaseIterable {
        case distance, angle, profile

        /// A segment's two ends; an angle's A, its vertex B, and C.
        package var pointCount: Int { self == .angle ? 3 : 2 }
    }

    package let kind: Kind
    /// `kind.pointCount` points; an angle's vertex is the middle one.
    package let points: [ImagePoint]
    /// A profile's width in pixels; 1 for the other kinds.
    package let width: Int

    package init(kind: Kind, points: [ImagePoint], width: Int = 1) {
        precondition(points.count == kind.pointCount, "SessionMark: \(points.count) points for a \(kind)")
        self.kind = kind
        self.points = points
        self.width = kind == .profile ? width : 1
    }
}

package nonisolated enum SessionMarks {
    /// The widest profile the room offers and the reader accepts, in pixels.
    package static let maximumWidth = 25
    /// The frame a node records: the reader opens frame 0 of a stack (V1-3c-ii gives the choice).
    package static let openedFrame = "0"

    private static let pointKeys = [("x1", "y1"), ("x2", "y2"), ("x3", "y3")]

    /// The bytes the smallest node a mark can record adds to a lineage's text (a distance of zero length on an uncalibrated
    /// image, an empty object, the shortest id and date), comma included: what the owner assumes a next mark costs before it is
    /// drawn (`recordingRefusal`). A real node is larger, so `add` is the exact check.
    package static let smallestNodeBytes: Int = {
        let mark = SessionMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 0, y: 0)])
        var lineage = SessionLineage()
        let empty = (try? lineage.jsonString().utf8.count) ?? 0
        // try? OK: a lineage of one small node always encodes; 0 only if it could not, which makes the estimate 0 and `add` exact.
        guard (try? lineage.add(kind: "distance", parameters: parameters(of: mark, object: ""),
                                results: results(of: mark, x: nil, y: nil, samples: nil), recorded: 0)) != nil,
              let one = try? lineage.jsonString().utf8.count else { return 0 }
        return one - empty + 1
    }()

    // MARK: - A mark to its node

    /// What the measurement took: the points, a profile's width, the object and the frame.
    package static func parameters(of mark: SessionMark, object: String, frame: String = openedFrame) -> [String: String] {
        var parameters = ["object": object, "frame": frame]
        for (point, keys) in zip(mark.points, pointKeys) {
            parameters[keys.0] = SessionLineage.coordinateString(point.x)
            parameters[keys.1] = SessionLineage.coordinateString(point.y)
        }
        if mark.kind == .profile { parameters["width"] = String(mark.width) }
        return parameters
    }

    /// What was measured, in the file's own units at full precision, and the scales it was measured with. `samples` is a
    /// profile's sample count (the owner has just measured it); nil for the other kinds.
    package static func results(of mark: SessionMark, x: AxisCalibration?, y: AxisCalibration?, samples: Int?) -> [String: String] {
        var results: [String: String] = [:]
        func number(_ key: String, _ value: Double) { results[key] = SessionLineage.coordinateString(value) }
        switch mark.kind {
        case .distance, .profile:
            let distance = ImageMeasurement.distance(mark.points[0], mark.points[1], x: x, y: y)
            number("pixels", distance.pixels)
            if let length = distance.physical, let unit = distance.unit {
                number("length", length)
                results["unit"] = unit
            }
            if mark.kind == .profile, let samples { results["samples"] = String(samples) }
        case .angle:
            if let angle = ImageMeasurement.angle(mark.points[0], vertex: mark.points[1], mark.points[2], x: x, y: y) {
                number("degrees", angle.degrees)
                results["plane"] = angle.plane == .physical ? "physical" : "pixel"
            }
        }
        if let x, x.isCalibrated { number("scale_x", x.scale); results["unit_x"] = x.unit }
        if let y, y.isCalibrated { number("scale_y", y.scale); results["unit_y"] = y.unit }
        return results
    }

    // MARK: - A node to its mark

    package nonisolated enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case missingKey(node: String, key: String)
        case badCoordinate(node: String, key: String, text: String)
        /// `point` counts from 1.
        case outsideImage(node: String, point: Int)
        case badWidth(node: String, text: String)

        package var reason: String {
            switch self {
            case .missingKey(let node, let key): "the mark \(node) has no \(key)"
            case .badCoordinate(let node, let key, let text): "the mark \(node)’s \(key) (“\(text)”) is not a finite number"
            case .outsideImage(let node, let point): "the mark \(node)’s point \(point) lies outside the image"
            case .badWidth(let node, let text):
                "the mark \(node)’s width (“\(text)”) is not a whole number of pixels from 1 to \(SessionMarks.maximumWidth)"
            }
        }

        package var description: String { reason }
    }

    /// The mark a node holds, checked against an image of `width` × `height` pixels; nil for a node that is not a mark
    /// this image draws (another kind, a removed node, another object or frame), which stays in the lineage untouched.
    package static func mark(of node: SessionLineage.Node, width: Int, height: Int, object: String,
                             frame: String = openedFrame) throws(Refusal) -> SessionMark? {
        guard node.removed == nil, let kind = SessionMark.Kind(rawValue: node.kind) else { return nil }
        func value(_ key: String) throws(Refusal) -> String {
            guard let text = node.parameters[key] else { throw .missingKey(node: node.id, key: key) }
            return text
        }
        guard try value("object") == object, try value("frame") == frame else { return nil }
        var points: [ImagePoint] = []
        for (index, keys) in pointKeys.prefix(kind.pointCount).enumerated() {
            var xy: [Double] = []
            for key in [keys.0, keys.1] {
                let text = try value(key)
                guard let number = coordinate(text) else { throw .badCoordinate(node: node.id, key: key, text: text) }
                xy.append(number)
            }
            let point = ImagePoint(x: xy[0], y: xy[1])
            guard point.x >= -0.5, point.x <= Double(width) - 0.5, point.y >= -0.5, point.y <= Double(height) - 0.5 else {
                throw .outsideImage(node: node.id, point: index + 1)
            }
            points.append(point)
        }
        var markWidth = 1
        if kind == .profile {
            let text = try value("width")
            guard let parsed = Self.width(text) else { throw .badWidth(node: node.id, text: text) }
            markWidth = parsed
        }
        return SessionMark(kind: kind, points: points, width: markWidth)
    }

    /// The writer's side of the reader's checks: every live mark node of `lineage` passes them against the image a save
    /// describes, so no save writes a sidecar this build would refuse.
    package static func check(_ lineage: SessionLineage, width: Int, height: Int, object: String) throws(Refusal) {
        for node in lineage.nodes { _ = try mark(of: node, width: width, height: height, object: object) }
    }

    /// A finite number written `-?digits(.digits)?(e[+-]?digits)?`, or nil.
    package static func coordinate(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        var at = 0
        func digits() -> Bool {
            let start = at
            while at < bytes.count, bytes[at] >= UInt8(ascii: "0"), bytes[at] <= UInt8(ascii: "9") { at += 1 }
            return at > start
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: "-") { at += 1 }
        guard digits() else { return nil }
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
            at += 1
            guard digits() else { return nil }
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: "e") {
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard digits() else { return nil }
        }
        guard at == bytes.count else { return nil }
        return SessionLineage.coordinate(from: text)
    }

    /// Plain digits, no sign and no leading zero, from 1 to `maximumWidth`; else nil.
    package static func width(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...2).contains(bytes.count), bytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              bytes[0] != UInt8(ascii: "0"), let value = Int(text), value <= maximumWidth else { return nil }
        return value
    }

    /// Whether a mark node was measured with other scales or units than the opened axes have: a recorded scale that
    /// differs, or an axis calibrated on one side and not on the other.
    package static func calibrationDiffers(_ node: SessionLineage.Node, x: AxisCalibration?, y: AxisCalibration?) -> Bool {
        func differs(_ axis: AxisCalibration?, scale key: String, unit unitKey: String) -> Bool {
            let recorded = node.results[key].flatMap(coordinate)
            guard let axis, axis.isCalibrated else { return recorded != nil || node.results[unitKey] != nil }
            return recorded != axis.scale || node.results[unitKey] != axis.unit
        }
        return differs(x, scale: "scale_x", unit: "unit_x") || differs(y, scale: "scale_y", unit: "unit_y")
    }
}

// MARK: - The restore

/// A read sidecar to the marks it restores, decided whole before anything is adopted. Nonisolated and pure: the caller
/// runs it, and the opened image's fingerprint, off the main actor.
package nonisolated enum SessionRestore {
    package struct Entry: Sendable, Equatable {
        package let nodeID: String
        package let mark: SessionMark
    }

    package struct Restored: Sendable, Equatable {
        /// `.adopt`, `.adoptRenamed` or `.adoptPixelsDiffer`; never `.refuse` (that is a `Refusal`).
        package let verdict: SessionRestoreVerdict
        /// As read (a read-only lineage has no nodes and records nothing).
        package let lineage: SessionLineage
        /// The marks to draw, in node order.
        package let marks: [Entry]
        /// Nodes kept in the lineage and not drawn: other kinds, removed nodes, another object or frame.
        package let kept: Int
        /// A drawn mark was measured with other scales or units than the opened axes have.
        package let calibrationDiffers: Bool
        /// The lineage attribute as it was read: a later save checks the file still holds it.
        package let lineageText: String
    }

    package nonisolated enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case missingSource
        case missingLineage
        case identity(SessionSourceIdentity.Refusal)
        case otherImage(String)
        case lineage(SessionLineage.Refusal)
        case mark(SessionMarks.Refusal)

        package var reason: String {
            switch self {
            case .missingSource: "the sidecar has no \(SessionSidecarFile.sourceAttribute): which image it describes is not recorded"
            case .missingLineage: "the sidecar has no \(SessionSidecarFile.lineageAttribute)"
            case .identity(let refusal): refusal.reason
            case .otherImage(let sentence): sentence
            case .lineage(let refusal): refusal.reason
            case .mark(let refusal): refusal.reason
            }
        }

        package var description: String { reason }
    }

    /// The identity first and the verdict on it, then the lineage, then every node: one refusal stops it, so nothing
    /// partial is ever handed back. `opened` is the identity of the image just read; `x` and `y` its axes.
    package static func restore(_ contents: SessionSidecarFile.Contents, opened: SessionSourceIdentity,
                                x: AxisCalibration?, y: AxisCalibration?) throws(Refusal) -> Restored {
        guard let sourceText = contents.source else { throw .missingSource }
        let stored: SessionSourceIdentity
        do throws(SessionSourceIdentity.Refusal) { stored = try SessionSourceIdentity.decode(sourceText) } catch { throw .identity(error) }
        let verdict = SessionRestoreVerdict.decide(stored: stored, opened: opened)
        if case .refuse(let sentence) = verdict { throw .otherImage(sentence) }

        guard let lineageText = contents.lineage else { throw .missingLineage }
        let lineage: SessionLineage
        do throws(SessionLineage.Refusal) { lineage = try SessionLineage.decode(lineageText) } catch { throw .lineage(error) }

        var marks: [Entry] = []
        var kept = 0
        var calibrationDiffers = false
        for node in lineage.nodes {
            let mark: SessionMark?
            do throws(SessionMarks.Refusal) {
                mark = try SessionMarks.mark(of: node, width: opened.width, height: opened.height, object: opened.object)
            } catch { throw .mark(error) }
            guard let mark else { kept += 1; continue }
            marks.append(Entry(nodeID: node.id, mark: mark))
            if SessionMarks.calibrationDiffers(node, x: x, y: y) { calibrationDiffers = true }
        }
        return Restored(verdict: verdict, lineage: lineage, marks: marks, kept: kept,
                        calibrationDiffers: calibrationDiffers, lineageText: lineageText)
    }
}

// MARK: - The save

/// What a save writes, as one Sendable value taken on the main actor and written off it.
package nonisolated enum SessionSave {
    package struct Request: Sendable, Equatable {
        package let source: String
        package let lineage: String
        /// The owner's revision when the request was taken: a mark changed during the write leaves the file unsaved.
        package let revision: Int
        /// The lineage the sidecar on disk held when it was restored or last saved; nil when this session has read none.
        package let expectedOnDisk: String?
        /// The user chose to replace the sidecar on disk, whatever it holds (a refused or unread one).
        package let replacing: Bool

        package init(source: String, lineage: String, revision: Int, expectedOnDisk: String?, replacing: Bool) {
            self.source = source
            self.lineage = lineage
            self.revision = revision
            self.expectedOnDisk = expectedOnDisk
            self.replacing = replacing
        }
    }

    package nonisolated enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// The lineage is a newer version's: it is never rewritten.
        case readOnly(Int)
        /// The sidecar was refused when the file was opened; saving over it waits for the user's choice to replace it.
        case sidecarRefused(String)
        case mark(SessionMarks.Refusal)
        case identity(SessionSourceIdentity.Refusal)
        case lineage(SessionLineage.Refusal)
        /// The sidecar on disk is not the one this session restored or last saved (another app or machine wrote it), or
        /// there is one this session never read.
        case changedOnDisk
        case file(SessionSidecarFile.Refusal)

        package var reason: String {
            switch self {
            case .readOnly(let version):
                "its marks were recorded by a newer macTEM (lineage version \(version)); this one does not rewrite them"
            case .sidecarRefused(let reason): "the session file beside it was not restored (\(reason))"
            case .mark(let refusal): refusal.reason
            case .identity(let refusal): refusal.reason
            case .lineage(let refusal): refusal.reason
            case .changedOnDisk: "the session file beside it has changed since this window read it"
            case .file(let refusal): refusal.reason
            }
        }

        package var description: String { reason }
    }

    /// The two strings of a save of `lineage` on the image `identity` describes (its object is the one the marks were
    /// drawn on), each mark node checked first with the restore's own checks.
    package static func request(identity: SessionSourceIdentity, lineage: SessionLineage, revision: Int,
                                expectedOnDisk: String?, replacing: Bool) throws(Refusal) -> Request {
        guard !lineage.isReadOnly else { throw .readOnly(lineage.fileVersion) }
        do throws(SessionMarks.Refusal) {
            try SessionMarks.check(lineage, width: identity.width, height: identity.height, object: identity.object)
        } catch { throw .mark(error) }
        let source: String
        do throws(SessionSourceIdentity.Refusal) { source = try identity.jsonString() } catch { throw .identity(error) }
        let text: String
        do throws(SessionLineage.Refusal) { text = try lineage.jsonString() } catch { throw .lineage(error) }
        let total = SessionSidecarFile.totalTextBytes(sourceBytes: source.utf8.count, lineageBytes: text.utf8.count)
        guard total <= SessionSidecarFile.maxTotalTextBytes else { throw .file(.sidecarTooLarge(bytes: total)) }
        return Request(source: source, lineage: text, revision: revision, expectedOnDisk: expectedOnDisk, replacing: replacing)
    }

    /// Writes `request` to the sidecar at `url`, unless the file there is not the one this session read: what it holds
    /// must be `expectedOnDisk` (or nothing, when that is nil), unless the user chose to replace it. Blocks on the HDF5
    /// lock and the disk: call it off the main actor.
    package static func write(_ request: Request, to url: URL) throws(Refusal) {
        if !request.replacing {
            var info = stat()
            let present = url.path.withCString { lstat($0, &info) } == 0
            if present {
                let onDisk: SessionSidecarFile.Contents
                do { onDisk = try SessionSidecarFile.read(url: url) }
                catch let refusal as SessionSidecarFile.Refusal { throw .file(refusal) }
                catch { throw .file(.cannotOpen("\(error)")) }
                guard let expected = request.expectedOnDisk, onDisk.lineage == expected else { throw .changedOnDisk }
            }
        }
        do { try SessionSidecarFile.write(source: request.source, lineage: request.lineage, to: url) }
        catch let refusal as SessionSidecarFile.Refusal { throw .file(refusal) }
        catch { throw .file(.cannotWrite(operation: "writing the file", detail: "\(error)")) }
    }
}
