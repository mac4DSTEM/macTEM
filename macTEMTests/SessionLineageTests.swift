//
//  SessionLineageTests.swift
//  The session sidecar's records: the lineage's ids, replace and remove (a chain of
//  removed nodes kept while a citer lives and collected whole in one pass), its canonical JSON and exact round trip,
//  every R8 refusal by name, the read-only unknown version and the opaque unknown kind; the source identity's
//  fingerprint (pinned against Python's hashlib over the same bytes) and the restore verdict's outcomes. No file is
//  touched: the HDF5 layer stores the strings these types produce. Each test was broken first against its mutation
//  ; a review's additions (2026-10-13) were broken against the reviewer's
//  surviving mutants, and the re-verifier's six (2026-10-14: the sweep's edges, every input on add) against its own.
//

import ImagoCore
import XCTest
import Foundation
import TEMCore

nonisolated final class SessionLineageTests: XCTestCase {
    private let t0: Int64 = 1_791_900_000_123
    private let maximumBytes = SessionLineage.maximumJSONBytes

    // MARK: - Builders

    private func nodeJSON(_ id: String, inputs: [String] = [], kind: String = "distance") -> String {
        let edges = inputs.map { #"{"role":"input","step":"\#($0)"}"# }.joined(separator: ",")
        return #"{"external":[],"id":"\#(id)","inputs":[\#(edges)],"kind":"\#(kind)","parameters":{},"recorded":1,"results":{}}"#
    }

    private func lineageJSON(next: Int, _ nodes: [String] = [], version: Int = 1) -> String {
        #"{"next_id":\#(next),"nodes":[\#(nodes.joined(separator: ","))],"version":\#(version)}"#
    }

    private func refusal(_ json: String) -> SessionLineage.Refusal? {
        do throws(SessionLineage.Refusal) { _ = try SessionLineage.decode(json); return nil } catch { return error }
    }

    private func identityRefusal(_ json: String) -> SessionSourceIdentity.Refusal? {
        do throws(SessionSourceIdentity.Refusal) { _ = try SessionSourceIdentity.decode(json); return nil } catch { return error }
    }

    private func assertNoFloats(_ value: Any, _ path: String = "", file: StaticString = #filePath, line: UInt = #line) {
        if let number = value as? NSNumber {
            XCTAssertFalse(["d", "f"].contains(String(cString: number.objCType)), path, file: file, line: line)
        } else if let object = value as? [String: Any] {
            for (key, member) in object { assertNoFloats(member, path + "/" + key, file: file, line: line) }
        } else if let array = value as? [Any] {
            for (index, member) in array.enumerated() { assertNoFloats(member, path + "/\(index)", file: file, line: line) }
        }
    }

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Ids, replace, remove

    func testAnIdIsNeverReusedAfterADelete() throws {
        var lineage = SessionLineage()
        XCTAssertEqual(try lineage.add(kind: "distance", parameters: [:], recorded: t0), "s1")
        XCTAssertEqual(try lineage.add(kind: "angle", parameters: [:], recorded: t0), "s2")
        XCTAssertEqual(try lineage.add(kind: "profile", parameters: [:], recorded: t0), "s3")
        XCTAssertEqual(lineage.remove(id: "s3"), .deleted)
        // The highest id was deleted: the next one is s4, not s3 again.
        XCTAssertEqual(try lineage.add(kind: "distance", parameters: [:], recorded: t0), "s4")
        XCTAssertEqual(lineage.remove(id: "s1"), .deleted)
        XCTAssertEqual(lineage.remove(id: "s2"), .deleted)
        XCTAssertEqual(lineage.remove(id: "s4"), .deleted)
        XCTAssertTrue(lineage.nodes.isEmpty)
        XCTAssertEqual(lineage.nextID, 5)
        XCTAssertEqual(try lineage.add(kind: "distance", parameters: [:], recorded: t0), "s5")
        // The counter survives a write and a read: a re-opened session does not reuse an id either.
        XCTAssertEqual(lineage.remove(id: "s5"), .deleted)
        var reopened = try SessionLineage.decode(try lineage.jsonString())
        XCTAssertEqual(reopened.nextID, 6)
        XCTAssertEqual(try reopened.add(kind: "distance", parameters: [:], recorded: t0), "s6")
    }

    func testReplaceChangesTheNodeInPlace() throws {
        var lineage = SessionLineage()
        let first = try lineage.add(kind: "distance", parameters: ["x1": "1.0"], results: ["length": "1"], recorded: t0)
        let second = try lineage.add(kind: "profile", parameters: ["x1": "2.0"], recorded: t0)
        let third = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: first, role: "mark")], recorded: t0)
        XCTAssertTrue(lineage.replace(id: first, parameters: ["x1": "9.5"], results: ["length": "9.5"], recorded: t0 + 1000))
        // The same id at the same position, the kind and the inputs untouched, no node added.
        XCTAssertEqual(lineage.nodes.map(\.id), [first, second, third])
        XCTAssertEqual(lineage.nextID, 4)
        let node = try XCTUnwrap(lineage.node(id: first))
        XCTAssertEqual(node.kind, "distance")
        XCTAssertEqual(node.parameters, ["x1": "9.5"])
        XCTAssertEqual(node.results, ["length": "9.5"])
        XCTAssertEqual(node.recorded, t0 + 1000)
        XCTAssertEqual(try XCTUnwrap(lineage.node(id: third)).inputs, [.init(step: first, role: "mark")])
        // An unknown id changes nothing.
        let before = lineage
        XCTAssertFalse(lineage.replace(id: "s99", parameters: [:], results: [:], recorded: t0))
        XCTAssertEqual(lineage, before)
        // Nor does a node the user removed (it stays only for its citer).
        XCTAssertEqual(lineage.remove(id: first), .kept)
        let kept = lineage
        XCTAssertFalse(lineage.replace(id: first, parameters: ["x1": "0"], results: [:], recorded: t0))
        XCTAssertEqual(lineage, kept)
    }

    func testRemovingAnUncitedNodeDeletesIt() throws {
        var lineage = SessionLineage()
        _ = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        _ = try lineage.add(kind: "angle", parameters: [:], recorded: t0)
        XCTAssertEqual(lineage.remove(id: "s1", at: t0 + 5), .deleted)
        XCTAssertEqual(lineage.nodes.map(\.id), ["s2"])
        XCTAssertNil(lineage.node(id: "s1"))
        XCTAssertEqual(lineage.remove(id: "s1"), .absent)
        XCTAssertEqual(lineage.nodes.map(\.id), ["s2"])
    }

    func testRemovingACitedNodeKeepsItWithARemovedDateUntilItsCiterGoes() throws {
        var lineage = SessionLineage()
        let mark = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let other = try lineage.add(kind: "angle", parameters: [:], recorded: t0)
        let export = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: mark, role: "mark")], recorded: t0)
        // The export cites the mark: removing the mark keeps the node, dated; it is no longer live.
        XCTAssertEqual(lineage.remove(id: mark, at: t0 + 7), .kept)
        XCTAssertEqual(try XCTUnwrap(lineage.node(id: mark)).removed, t0 + 7)
        XCTAssertEqual(lineage.nodes.map(\.id), [mark, other, export])
        XCTAssertEqual(lineage.liveNodes.map(\.id), [other, export])
        // Removing it again keeps the first date.
        XCTAssertEqual(lineage.remove(id: mark, at: t0 + 99), .kept)
        XCTAssertEqual(try XCTUnwrap(lineage.node(id: mark)).removed, t0 + 7)
        // It survives a write and a read with its date.
        let reread = try SessionLineage.decode(try lineage.jsonString())
        XCTAssertEqual(reread, lineage)
        // The citer goes: the kept node goes with it, and its id is still not given back.
        XCTAssertEqual(lineage.remove(id: export), .deleted)
        XCTAssertEqual(lineage.nodes.map(\.id), [other])
        XCTAssertEqual(lineage.nextID, 4)
    }

    func testAnInputNamingAMissingNodeIsRefusedAndConsumesNoId() throws {
        var lineage = SessionLineage()
        _ = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let before = lineage
        XCTAssertThrowsError(try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: "s9", role: "mark")], recorded: t0)) {
            XCTAssertEqual($0 as? SessionLineage.Refusal, .danglingInput(step: "s9", from: "s2"))
        }
        XCTAssertEqual(lineage, before)
    }

    func testAnInputNamingARemovedNodeIsRefused() throws {
        var lineage = SessionLineage()
        let mark = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: mark, role: "mark")], recorded: t0)
        // The export cites the mark, so removing it keeps the node, dated; a removed node is not an input for a new one.
        XCTAssertEqual(lineage.remove(id: mark), .kept)
        let before = lineage
        XCTAssertThrowsError(try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: mark, role: "mark")], recorded: t0)) {
            XCTAssertEqual($0 as? SessionLineage.Refusal, .danglingInput(step: mark, from: "s3"))
        }
        XCTAssertEqual(lineage, before)   // and no id was spent
    }

    func testEveryInputOfANewNodeIsCheckedNotOnlyTheFirst() throws {
        // The first input is live in both adds; the second names a missing node, then a removed one. Red under: only the
        // first input checked (the re-verifier's N2a, 2026-10-14).
        var lineage = SessionLineage()
        let a = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let removed = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: removed, role: "x")], recorded: t0)
        XCTAssertEqual(lineage.remove(id: removed), .kept)
        let before = lineage
        XCTAssertThrowsError(try lineage.add(kind: "export", parameters: [:],
                                             inputs: [.init(step: a, role: "x"), .init(step: "s99", role: "y")], recorded: t0))
        XCTAssertThrowsError(try lineage.add(kind: "export", parameters: [:],
                                             inputs: [.init(step: a, role: "x"), .init(step: removed, role: "y")], recorded: t0))
        XCTAssertEqual(lineage, before)
    }

    func testAChainOfRemovedNodesIsKeptWhileACiterLivesAndCollectedWholeWhenItGoes() throws {
        var lineage = SessionLineage()
        let a = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        // One node citing the same input under two roles (the second edge must be counted and released too).
        let b = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: a, role: "mark"), .init(step: a, role: "scale")], recorded: t0)
        let c = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: b, role: "table")], recorded: t0)
        // The middle one first: cited by c, so dated and kept. Then a, which only the removed b cites: it must stay too,
        // or b would name a node that is not there and the lineage could no longer be written.
        XCTAssertEqual(lineage.remove(id: b, at: t0 + 1), .kept)
        XCTAssertEqual(lineage.remove(id: a, at: t0 + 2), .kept)
        XCTAssertEqual(lineage.nodes.map(\.id), [a, b, c])
        XCTAssertEqual(try SessionLineage.decode(try lineage.jsonString()), lineage)
        // The last citer goes: the whole chain goes with it (b, then a), not just the first link.
        XCTAssertEqual(lineage.remove(id: c), .deleted)
        XCTAssertTrue(lineage.nodes.isEmpty, "\(lineage.nodes.map(\.id))")
        XCTAssertEqual(lineage.nextID, 4)
        // A longer chain, removed from the top: every link is a removed node citing the one below it.
        var long = SessionLineage()
        var previous = try long.add(kind: "distance", parameters: [:], recorded: t0)
        for _ in 0..<6 { previous = try long.add(kind: "export", parameters: [:], inputs: [.init(step: previous, role: "x")], recorded: t0) }
        for id in long.nodes.map(\.id).dropLast().reversed() { XCTAssertEqual(long.remove(id: id), .kept) }
        XCTAssertEqual(long.nodes.count, 7)
        XCTAssertEqual(long.remove(id: previous), .deleted)
        XCTAssertTrue(long.nodes.isEmpty)
    }

    func testANodeMayCiteTheSameInputTwiceUnderTwoRoles() throws {
        var lineage = SessionLineage()
        let a = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let b = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: a, role: "x"), .init(step: a, role: "y")], recorded: t0)
        XCTAssertEqual(try SessionLineage.decode(try lineage.jsonString()), lineage)   // two edges to one node are not a cycle
        XCTAssertEqual(lineage.remove(id: a), .kept)
        XCTAssertEqual(lineage.remove(id: b), .deleted)
        XCTAssertTrue(lineage.nodes.isEmpty)
    }

    // The sweep's edges, each pinned by the mutant of 2026-10-14's re-verifier that survived every earlier test (N1a, N1c,
    // N1d, N1g, N1i): only removed nodes are collected, only when nothing cites them, all of them in one removal, an edge
    // released as often as it was counted, and every input of a node counted, not only its first.

    func testALiveNodeStaysWhenTheRemovedNodeCitingItIsCollected() throws {
        // x is live; t, removed, cites it; c cites t. Removing c collects t, and x loses its last citer but is not removed.
        // Red under: a node collected when its citations reach zero, removed or not.
        var lineage = SessionLineage()
        let x = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let t = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: x, role: "mark")], recorded: t0)
        let c = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: t, role: "table")], recorded: t0)
        XCTAssertEqual(lineage.remove(id: t), .kept)
        XCTAssertEqual(lineage.remove(id: c), .deleted)
        XCTAssertEqual(lineage.nodes.map(\.id), [x])
        XCTAssertEqual(lineage.liveNodes.map(\.id), [x])
        XCTAssertNoThrow(try lineage.jsonString())
    }

    func testARemovedNodeStillCitedStaysWhenAnotherNodeIsRemoved() throws {
        // Removing an unrelated mark must not collect the removed mark the export still cites. Red under: the sweep seeded
        // with every removed node, cited or not.
        var lineage = SessionLineage()
        let mark = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let other = try lineage.add(kind: "angle", parameters: [:], recorded: t0)
        let export = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: mark, role: "mark")], recorded: t0)
        XCTAssertEqual(lineage.remove(id: mark), .kept)
        XCTAssertEqual(lineage.remove(id: other), .deleted)
        XCTAssertEqual(lineage.nodes.map(\.id), [mark, export])
        XCTAssertNoThrow(try lineage.jsonString())
    }

    func testEveryNodeOrphanedByARemovalGoesInThatRemoval() throws {
        // d cites a and b, both removed; removing d orphans both. Red under: the sweep seeded with the first orphan only.
        var lineage = SessionLineage()
        let a = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let b = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let d = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: a, role: "x"), .init(step: b, role: "y")], recorded: t0)
        XCTAssertEqual(lineage.remove(id: a), .kept)
        XCTAssertEqual(lineage.remove(id: b), .kept)
        XCTAssertEqual(lineage.remove(id: d), .deleted)
        XCTAssertTrue(lineage.nodes.isEmpty, "\(lineage.nodes.map(\.id))")
    }

    func testAnInputCitedTwiceByACollectedNodeStaysWhileAnotherNodeCitesIt() throws {
        // a is cited twice by t and once by the live e. Collecting t releases two edges to a, leaving e's. Red under:
        // citations counted once per cited node but released once per edge.
        var lineage = SessionLineage()
        let a = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let t = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: a, role: "x"), .init(step: a, role: "y")], recorded: t0)
        let e = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: a, role: "z")], recorded: t0)
        let c = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: t, role: "w")], recorded: t0)
        XCTAssertEqual(lineage.remove(id: a), .kept)
        XCTAssertEqual(lineage.remove(id: t), .kept)
        XCTAssertEqual(lineage.remove(id: c), .deleted)
        XCTAssertEqual(lineage.nodes.map(\.id), [a, e])
        XCTAssertNoThrow(try lineage.jsonString())
    }

    func testANodeCitedOnlyAsASecondInputIsKeptWhenRemoved() throws {
        // Red under: a node counted as cited only when it is a citer's first input.
        var lineage = SessionLineage()
        let a = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let b = try lineage.add(kind: "distance", parameters: [:], recorded: t0)
        let e = try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: a, role: "x"), .init(step: b, role: "y")], recorded: t0)
        XCTAssertEqual(lineage.remove(id: b), .kept)
        XCTAssertEqual(lineage.nodes.map(\.id), [a, b, e])
        XCTAssertNoThrow(try lineage.jsonString())
    }

    func testRemovingTheEndOfAChainOfTwoThousandRemovedNodesIsOnePass() throws {
        // Planted as a file would carry it, inside every cap: s1 … s2000, each citing the one below it, all removed but
        // the last. Removing that one collects the whole chain; rescanning every node per deletion took 19 s here.
        let count = SessionLineage.maximumNodes
        let chain = (1...count).map { number -> String in
            let input = number == 1 ? "" : #"{"role":"x","step":"s\#(number - 1)"}"#
            let removed = number == count ? "" : #""removed":1,"#
            return #"{"id":"s\#(number)","inputs":[\#(input)],"kind":"export",\#(removed)"recorded":1}"#
        }
        var planted = try SessionLineage.decode(lineageJSON(next: count + 1, chain))
        XCTAssertEqual(planted.nodes.count, count)
        XCTAssertEqual(planted.liveNodes.map(\.id), ["s\(count)"])
        let start = Date()
        XCTAssertEqual(planted.remove(id: "s\(count)"), .deleted)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertTrue(planted.nodes.isEmpty)
        XCTAssertLessThan(seconds, 2.0, "the sweep rescans the graph once per deleted node (about a millisecond when it is one pass)")
    }

    func testTheNodeAndIdBoundsHold() throws {
        var lineage = SessionLineage()
        for _ in 0..<SessionLineage.maximumNodes { try lineage.add(kind: "distance", parameters: [:], recorded: t0) }
        let full = lineage
        XCTAssertThrowsError(try lineage.add(kind: "distance", parameters: [:], recorded: t0)) {
            XCTAssertEqual($0 as? SessionLineage.Refusal, .tooManyNodes(SessionLineage.maximumNodes + 1))
        }
        XCTAssertEqual(lineage, full)
        // A full lineage is still one the reader takes.
        XCTAssertEqual(try SessionLineage.decode(try full.jsonString()), full)

        // Every id spent: s999999 is the last, and what the file then carries is still readable.
        var late = try SessionLineage.decode(lineageJSON(next: SessionLineage.maximumNextID - 1))
        XCTAssertEqual(try late.add(kind: "distance", parameters: [:], recorded: t0), "s999999")
        let spent = late
        XCTAssertThrowsError(try late.add(kind: "distance", parameters: [:], recorded: t0)) {
            XCTAssertEqual($0 as? SessionLineage.Refusal, .idsExhausted)
        }
        XCTAssertEqual(late, spent)
        XCTAssertEqual(try SessionLineage.decode(try spent.jsonString()), spent)
    }

    // MARK: - Time and coordinates

    func testDatesAreIntegerMillisecondsAndQuantiseOnce() {
        // 1 791 900 000.1234 s → …123 ms; seconds would lose the 123.
        let date = Date(timeIntervalSince1970: 1_791_900_000.1234)
        XCTAssertEqual(SessionLineage.milliseconds(date), 1_791_900_000_123)
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: 1_791_900_000.1236)), 1_791_900_000_124)
        XCTAssertNotEqual(SessionLineage.milliseconds(date) % 1000, 0)
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: -1.5)), -1500)
        // Quantising a quantised date changes nothing: a re-read equals exactly.
        var generator = SplitMix64(state: 7)
        for _ in 0..<5000 {
            let ms = Int64(bitPattern: generator.next() % 8_000_000_000_000) - 2_000_000_000_000
            XCTAssertEqual(SessionLineage.milliseconds(SessionLineage.date(milliseconds: ms)), ms)
        }
        // A tie goes away from zero: 1/16 s is exactly 62.5 ms (a dyadic second, so the Date holds it exactly).
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: 0.0625)), 63)
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: -0.0625)), -63)
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: 1_791_900_000.0625)), 1_791_900_000_063)
        // Idempotent over the whole range the doc states, ±4e15 ms (year ±127 000), both ends included.
        let bound: Int64 = 4_000_000_000_000_000
        for ms in [bound, -bound, bound - 1, 1 - bound, 2_251_799_813_685_248, -2_251_799_813_685_248] {
            XCTAssertEqual(SessionLineage.milliseconds(SessionLineage.date(milliseconds: ms)), ms)
        }
        for _ in 0..<20_000 {
            let ms = Int64(generator.next() % UInt64(2 * bound + 1)) - bound
            XCTAssertEqual(SessionLineage.milliseconds(SessionLineage.date(milliseconds: ms)), ms)
        }
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: .nan)), 0)
        // What no millisecond count can hold is clamped, at either end.
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: .infinity)), 9_000_000_000_000_000)
        XCTAssertEqual(SessionLineage.milliseconds(Date(timeIntervalSince1970: -.infinity)), -9_000_000_000_000_000)
    }

    func testCoordinatesRoundTripBitExact() throws {
        var values: [Double] = [0.1, 1e-300, -0.0, 0.0, 16_777_217.5, 0.1 + 0.2, .pi, -.pi, 1e300, 5e-324, 4.35, 123456789.123456789,
                                .leastNormalMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1.0 / 3.0, 2048.0]
        var generator = SplitMix64(state: 42)
        while values.count < 3000 {
            let value = Double(bitPattern: generator.next())
            if value.isFinite { values.append(value) }
        }
        for value in values {
            let string = SessionLineage.coordinateString(value)
            let back = try XCTUnwrap(SessionLineage.coordinate(from: string), string)
            XCTAssertEqual(back.bitPattern, value.bitPattern, string)
        }
        XCTAssertEqual(SessionLineage.coordinateString(0.1), "0.1")
        XCTAssertEqual(SessionLineage.coordinateString(-0.0), "-0.0")
        XCTAssertEqual(SessionLineage.coordinateString(16_777_217.5), "16777217.5")
        XCTAssertEqual(SessionLineage.coordinateString(1e-300), "1e-300")
        XCTAssertNil(SessionLineage.coordinate(from: "nan"))
        XCTAssertNil(SessionLineage.coordinate(from: "inf"))
        XCTAssertNil(SessionLineage.coordinate(from: "1,5"))
        XCTAssertNil(SessionLineage.coordinate(from: ""))

        // Through the lineage's JSON: the same strings, so the same bits, and `recorded` equal.
        var lineage = SessionLineage()
        var parameters: [String: String] = [:]
        for (index, value) in values.prefix(600).enumerated() { parameters["p\(index)"] = SessionLineage.coordinateString(value) }
        let id = try lineage.add(kind: "profile", parameters: parameters, recorded: SessionLineage.milliseconds(Date(timeIntervalSince1970: 1_791_900_000.4567)))
        let reread = try SessionLineage.decode(try lineage.jsonString())
        XCTAssertEqual(reread, lineage)
        let node = try XCTUnwrap(reread.node(id: id))
        XCTAssertEqual(node.recorded, 1_791_900_000_457)
        for (index, value) in values.prefix(600).enumerated() {
            let back = try XCTUnwrap(SessionLineage.coordinate(from: try XCTUnwrap(node.parameters["p\(index)"])))
            XCTAssertEqual(back.bitPattern, value.bitPattern)
        }
    }

    // MARK: - The JSON

    private func sampleLineage() throws -> SessionLineage {
        var lineage = SessionLineage()
        let mark = try lineage.add(
            kind: SessionLineage.Kind.distance,
            parameters: ["y2": "20.0", "x2": "40.25", "object": "ImageList.1 · HAADF", "x1": "10.5", "y1": "20.0", "frame": "1"],
            results: ["unit": "nm", "length": "29.75"], recorded: 1_791_900_000_123)
        try lineage.add(kind: "export", parameters: ["format": "csv"], inputs: [.init(step: mark, role: "mark")],
                        recorded: 1_791_900_000_456)
        return lineage
    }

    func testTheJSONIsCanonicalSortedAndByteStable() throws {
        let golden = #"{"next_id":3,"nodes":[{"external":[],"id":"s1","inputs":[],"kind":"distance","parameters":{"frame":"1","object":"ImageList.1 · HAADF","x1":"10.5","x2":"40.25","y1":"20.0","y2":"20.0"},"recorded":1791900000123,"results":{"length":"29.75","unit":"nm"}},{"external":[],"id":"s2","inputs":[{"role":"mark","step":"s1"}],"kind":"export","parameters":{"format":"csv"},"recorded":1791900000456,"results":{}}],"version":1}"#
        let lineage = try sampleLineage()
        XCTAssertEqual(try lineage.jsonString(), golden)
        // Re-encoding what was decoded gives the same bytes, any number of times.
        var text = golden
        for _ in 0..<3 {
            let decoded = try SessionLineage.decode(text)
            XCTAssertEqual(decoded, lineage)
            text = try decoded.jsonString()
            XCTAssertEqual(Array(text.utf8), Array(golden.utf8))
        }
        // A kept node carries `removed`, between `recorded` and `results`, and survives the same loop.
        var withRemoved = lineage
        XCTAssertEqual(withRemoved.remove(id: "s1", at: 1_791_900_000_999), .kept)
        let removedJSON = try withRemoved.jsonString()
        XCTAssertTrue(removedJSON.contains(#""recorded":1791900000123,"removed":1791900000999,"results""#), removedJSON)
        XCTAssertEqual(try SessionLineage.decode(removedJSON).jsonString(), removedJSON)
        // No float anywhere: every number in the text is an integer (measurements are strings).
        assertNoFloats(try JSONSerialization.jsonObject(with: Data(golden.utf8)))
        // (A slash is not escaped: `testASlashIsWrittenAsItIsInBothRecords`; the sample holds none.)
    }

    func testASlashIsWrittenAsItIsInBothRecords() throws {
        // "1/nm" is a real unit. Foundation escapes "/" as "\/" unless told not to, and h5py's reader and the parity
        // harness compare the text byte for byte.
        var lineage = SessionLineage()
        try lineage.add(kind: "distance", parameters: ["note": "a/b", "a/b": "1/nm"], recorded: t0)
        let text = try lineage.jsonString()
        XCTAssertTrue(text.contains(#""note":"a/b""#), text)
        XCTAssertTrue(text.contains(#""a/b":"1/nm""#), text)
        XCTAssertFalse(text.contains("\\/"), text)
        let source = identity(object: "ImageList.2/HAADF")
        let sourceText = try source.jsonString()
        XCTAssertTrue(sourceText.contains(#""object":"ImageList.2/HAADF""#), sourceText)
        XCTAssertFalse(sourceText.contains("\\/"), sourceText)
        XCTAssertEqual(try SessionSourceIdentity.decode(sourceText), source)
    }

    func testTextRoundTripsExactly() throws {
        // "Å" (U+00C5), "µ" (U+00B5), "·", a NUL, quotes, backslash, slash, a newline, an astral character.
        var lineage = SessionLineage()
        let tricky = ["Å", "µm", "ImageList.2 · HAADF", "a\u{0}b", "q\"uote", "back\\slash", "a/b", "line\nbreak", "𝛼 😀", "\u{0301}"]
        var parameters: [String: String] = [:]
        for (index, text) in tricky.enumerated() { parameters["k\(index)\(text)"] = text }
        try lineage.add(kind: "distance", parameters: parameters, results: ["unit": "µm", "name": "Å"], recorded: t0)
        let text = try lineage.jsonString()
        let reread = try SessionLineage.decode(text)
        XCTAssertEqual(reread, lineage)
        XCTAssertEqual(try reread.jsonString(), text)
        // Compared as scalars: Swift's == would equate canonically equivalent texts and hide a normalisation.
        for (key, value) in parameters {
            XCTAssertEqual(reread.nodes[0].parameters[key]?.unicodeScalars.map(\.value), value.unicodeScalars.map(\.value))
        }
    }

    func testAnUnknownKindIsKeptOpaque() throws {
        let json = #"{"next_id":3,"nodes":[{"external":[{"fingerprint":"abc","name":"x.cif"}],"id":"s1","inputs":[],"kind":"lattice_fit_v9","parameters":{"a":"1"},"recorded":5,"results":{"b":"2"}},{"external":[],"id":"s2","inputs":[{"role":"future","step":"s1"}],"kind":"export","parameters":{},"recorded":6,"results":{}}],"version":1}"#
        let lineage = try SessionLineage.decode(json)
        XCTAssertEqual(lineage.nodes.map(\.kind), ["lattice_fit_v9", "export"])
        XCTAssertEqual(lineage.nodes[0].parameters, ["a": "1"])
        XCTAssertEqual(lineage.nodes[0].external, [.init(name: "x.cif", fingerprint: "abc")])
        XCTAssertEqual(lineage.nodes[1].inputs, [.init(step: "s1", role: "future")])
        // Kept through a rewrite, byte for byte.
        XCTAssertEqual(try lineage.jsonString(), json)
    }

    func testAbsentCollectionsAreEmptyAndUnknownKeysAreKept() throws {
        let json = #"{"extra":[1,2],"next_id":2,"nodes":[{"colour":"red","id":"s1","kind":"angle","recorded":9}],"version":1}"#
        let lineage = try SessionLineage.decode(json)
        XCTAssertEqual(lineage.nodes, [SessionLineage.Node(id: "s1", kind: "angle", parameters: [:], recorded: 9,
                                                           unknown: ["colour": .string("red")])])
        XCTAssertEqual(lineage.nextID, 2)
        XCTAssertEqual(lineage.unknownKeys, ["extra": .array([.integer(1), .integer(2)])])
    }

    func testUnknownNodesAndKeysSurviveARewriteAndAnEdit() throws {
        // Another writer's version-1 lineage: a root key, a node key and a node of a kind this build does not know, with
        // every JSON shape a value can take.
        let json = #"{"next_id":3,"nodes":[{"external":[],"id":"s1","inputs":[],"kind":"distance","note":{"by":"them","n":[1,2.5,-0.003,true,null]},"parameters":{"x1":"1.0"},"recorded":5,"results":{}},{"external":[],"id":"s2","inputs":[],"kind":"their_kind","parameters":{},"recorded":6,"results":{},"weight":0.25}],"producer":{"name":"other","version":"2.1"},"version":1}"#
        var lineage = try SessionLineage.decode(json)
        XCTAssertEqual(try lineage.jsonString(), json, "kept byte for byte through a rewrite")
        XCTAssertEqual(try SessionLineage.decode(try lineage.jsonString()), lineage)
        // An edit of the known node and a new node leave every unknown key where it was.
        XCTAssertTrue(lineage.replace(id: "s1", parameters: ["x1": "2.0"], results: [:], recorded: 7))
        try lineage.add(kind: "angle", parameters: [:], recorded: 8)
        let edited = try SessionLineage.decode(try lineage.jsonString())
        XCTAssertEqual(edited.unknownKeys["producer"], .object(["name": .string("other"), "version": .string("2.1")]))
        XCTAssertEqual(edited.node(id: "s1")?.unknown["note"], lineage.node(id: "s1")?.unknown["note"])
        XCTAssertEqual(edited.node(id: "s2")?.unknown, ["weight": .number(0.25)])
        XCTAssertEqual(edited.node(id: "s2")?.kind, "their_kind")
        XCTAssertEqual(edited.node(id: "s3")?.unknown, [:])
        // Red under: unknown keys ignored by the reader (the rewrite drops "producer", "note" and "weight").
    }

    // MARK: - The R8 refusals

    func testAnOversizeLineageIsRefusedByUTF8BytesAndTheCapItselfIsAccepted() throws {
        let base = lineageJSON(next: 1)
        let atCap = base + String(repeating: " ", count: maximumBytes - base.utf8.count)
        XCTAssertEqual(atCap.utf8.count, maximumBytes)
        XCTAssertEqual(try SessionLineage.decode(atCap), SessionLineage())   // valid JSON: only the cap could refuse it
        XCTAssertEqual(refusal(atCap + " "), .tooLarge(bytes: maximumBytes + 1))
        // Counted in bytes, not characters: 2.1 million two-byte characters are under any character cap.
        let wide = lineageJSON(next: 2, [#"{"id":"s1","kind":"distance","parameters":{"k":"\#(String(repeating: "µ", count: 2_100_000))"},"recorded":1}"#])
        XCTAssertLessThan(wide.count, maximumBytes)
        XCTAssertGreaterThan(wide.utf8.count, maximumBytes)
        XCTAssertEqual(refusal(wide), .tooLarge(bytes: wide.utf8.count))
        // A newer version's file is not exempt from the cap.
        XCTAssertEqual(refusal(lineageJSON(next: 1, version: 2) + String(repeating: " ", count: maximumBytes)), .tooLarge(bytes: lineageJSON(next: 1, version: 2).utf8.count + maximumBytes))
    }

    func testTheWriterRefusesALineageTheReaderWouldRefuseForSize() throws {
        var lineage = SessionLineage()
        let megabyte = String(repeating: "x", count: 1_000_000)
        for _ in 0..<5 { try lineage.add(kind: "distance", parameters: ["note": megabyte], recorded: t0) }
        XCTAssertThrowsError(try lineage.jsonString()) {
            guard case .tooLarge(let bytes)? = $0 as? SessionLineage.Refusal else { return XCTFail("\($0)") }
            XCTAssertGreaterThan(bytes, maximumBytes)
        }
    }

    func testNotJSONAndTheWrongShapeAreMalformed() {
        let malformed = [
            "", " ", "not json", "{", "[]", "null", "3", #""text""#, "{}", #"{"version":1}"#, #"{"version":1,"next_id":1}"#,
            #"{"version":1,"next_id":1,"nodes":{}}"#, #"{"version":1,"next_id":1,"nodes":[1]}"#, #"{"version":1,"next_id":1,"nodes":null}"#,
            #"{"version":"1","next_id":1,"nodes":[]}"#, #"{"version":1.5,"next_id":1,"nodes":[]}"#,
            #"{"version":1,"next_id":"3","nodes":[]}"#, #"{"version":1,"next_id":1.5,"nodes":[]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"kind":"distance","recorded":1}]}"#,          // no id
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","recorded":1}]}"#,                  // no kind
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance"}]}"#,             // no recorded
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance","recorded":1.5}]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance","recorded":"7"}]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"id":1,"kind":"distance","recorded":1}]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance","recorded":1,"parameters":{"x":1.5}}]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance","recorded":1,"parameters":["x"]}]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance","recorded":1,"inputs":[{"step":"s1"}]}]}"#,
            #"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"distance","recorded":99999999999999999999}]}"#,
            "{\"version\":1,\"next_id\":1,\"nodes\":[]} trailing",
        ]
        for json in malformed {
            XCTAssertEqual(refusal(json), .malformed, json)
        }
        // Hostile nesting, within the byte cap, is refused rather than recursed into.
        let deep = String(repeating: "[", count: 100_000)
        XCTAssertEqual(refusal(deep), .malformed)
        XCTAssertEqual(refusal(#"{"version":1,"next_id":1,"nodes":"# + deep + String(repeating: "]", count: 100_000) + "}"), .malformed)
        XCTAssertEqual(refusal(#"{"version":1,"next_id":2,"nodes":[{"id":"s1","kind":"x","recorded":1,"parameters":"# + deep + "}]}"), .malformed)
    }

    func testMoreThanTwoThousandNodesAreRefused() {
        func json(count: Int) -> String { lineageJSON(next: count + 1, (1...count).map { nodeJSON("s\($0)") }) }
        XCTAssertNil(refusal(json(count: SessionLineage.maximumNodes)))
        XCTAssertEqual(refusal(json(count: SessionLineage.maximumNodes + 1)), .tooManyNodes(SessionLineage.maximumNodes + 1))
    }

    func testNextIDOutsideItsBoundIsRefused() {
        XCTAssertEqual(refusal(lineageJSON(next: 0)), .badNextID(0))
        XCTAssertEqual(refusal(lineageJSON(next: -1)), .badNextID(-1))
        XCTAssertEqual(refusal(lineageJSON(next: 1_000_001)), .badNextID(1_000_001))
        XCTAssertEqual(refusal(lineageJSON(next: Int(Int32.max) + 1)), .badNextID(Int(Int32.max) + 1))
        XCTAssertNil(refusal(lineageJSON(next: 1)))
        XCTAssertNil(refusal(lineageJSON(next: 1_000_000)))
    }

    func testAnIdNotOfTheFormIsRefused() {
        for id in ["", "s", "s0", "s01", "s+1", "s-1", "S1", "x1", "1", "s 1", "s1 ", "s1.0", "s1e2", "s١", "s1000001", "s0000001",
                   "s99999999999999999999", "ss1", " s1"] {
            XCTAssertEqual(refusal(lineageJSON(next: 1_000_000, [nodeJSON(id)])), .badID(id), id)
        }
        XCTAssertNil(refusal(lineageJSON(next: 1_000_000, [nodeJSON("s1"), nodeJSON("s10"), nodeJSON("s999999")])))
    }

    func testAnIdAtOrAboveNextIDIsRefused() {
        XCTAssertEqual(refusal(lineageJSON(next: 5, [nodeJSON("s5")])), .idNotBelowNextID(id: "s5", nextID: 5))
        XCTAssertEqual(refusal(lineageJSON(next: 5, [nodeJSON("s1"), nodeJSON("s9")])), .idNotBelowNextID(id: "s9", nextID: 5))
        XCTAssertEqual(refusal(lineageJSON(next: 1_000_000, [nodeJSON("s1000000")])), .idNotBelowNextID(id: "s1000000", nextID: 1_000_000))
        XCTAssertNil(refusal(lineageJSON(next: 6, [nodeJSON("s5")])))
        XCTAssertNil(refusal(lineageJSON(next: 1_000_000, [nodeJSON("s999999")])))
    }

    func testARepeatedIdIsRefused() {
        XCTAssertEqual(refusal(lineageJSON(next: 3, [nodeJSON("s1"), nodeJSON("s2"), nodeJSON("s1")])), .duplicateID("s1"))
    }

    func testAnInputNamingAMissingNodeIsRefused() {
        XCTAssertEqual(refusal(lineageJSON(next: 3, [nodeJSON("s1"), nodeJSON("s2", inputs: ["s9"])])), .danglingInput(step: "s9", from: "s2"))
        XCTAssertNil(refusal(lineageJSON(next: 3, [nodeJSON("s1"), nodeJSON("s2", inputs: ["s1"])])))
    }

    func testACycleIsRefusedAndADiamondIsNot() {
        XCTAssertEqual(refusal(lineageJSON(next: 2, [nodeJSON("s1", inputs: ["s1"])])), .cycle)
        XCTAssertEqual(refusal(lineageJSON(next: 3, [nodeJSON("s1", inputs: ["s2"]), nodeJSON("s2", inputs: ["s1"])])), .cycle)
        XCTAssertEqual(refusal(lineageJSON(next: 5, [nodeJSON("s1", inputs: ["s3"]), nodeJSON("s2", inputs: ["s1"]),
                                                     nodeJSON("s3", inputs: ["s2"]), nodeJSON("s4")])), .cycle)
        // A graph with a shared input and two inputs is acyclic.
        XCTAssertNil(refusal(lineageJSON(next: 5, [nodeJSON("s1"), nodeJSON("s2", inputs: ["s1"]), nodeJSON("s3", inputs: ["s1"]),
                                                   nodeJSON("s4", inputs: ["s2", "s3"])])))
    }

    func testAnUnknownVersionIsReadOnlyNotRefused() throws {
        // A newer build may reshape its nodes entirely: this build does not interpret them, and never rewrites.
        let reshaped = #"{"version":2,"next_id":9,"graph":{"s1":{"k":"distance"}},"nodes":{"s1":[1,2,3]}}"#
        for json in [reshaped, lineageJSON(next: 3, [nodeJSON("s1")], version: 2), #"{"version":0}"#, #"{"version":-4,"nodes":7}"#,
                     #"{"version":99}"#] {
            var lineage = try SessionLineage.decode(json)
            XCTAssertTrue(lineage.isReadOnly, json)
            XCTAssertTrue(lineage.nodes.isEmpty, json)
            XCTAssertNotEqual(lineage.fileVersion, SessionLineage.version)
            let version = lineage.fileVersion
            // Never extended, never changed, never written.
            XCTAssertThrowsError(try lineage.add(kind: "distance", parameters: [:], recorded: t0), json) {
                XCTAssertEqual($0 as? SessionLineage.Refusal, .unsupportedVersion(version))
            }
            XCTAssertThrowsError(try lineage.jsonString(), json) {
                XCTAssertEqual($0 as? SessionLineage.Refusal, .unsupportedVersion(version))
            }
            XCTAssertFalse(lineage.replace(id: "s1", parameters: [:], results: [:], recorded: t0))
            XCTAssertEqual(lineage.remove(id: "s1"), .absent)
        }
        XCTAssertFalse(try SessionLineage.decode(lineageJSON(next: 1)).isReadOnly)
        XCTAssertFalse(SessionLineage().isReadOnly)
        // No version at all, or one that is not an integer, is malformed, not "newer".
        XCTAssertEqual(refusal(#"{"next_id":1,"nodes":[]}"#), .malformed)
    }

    // MARK: - The source identity

    private func image(_ pixels: [Float], width: Int, height: Int, fileName: String = "scan.dm4",
                       source: String = "ImageList.2 · HAADF", x: AxisCalibration? = nil, y: AxisCalibration? = nil,
                       voltage: Double? = nil, notes: [String] = []) -> CalibratedImage {
        CalibratedImage(width: width, height: height, pixels: pixels, x: x, y: y, fileName: fileName, source: source,
                        voltage: voltage, notes: notes)
    }

    // The six values Python packs as '<6f' and hashes with hashlib.sha256 (see the pinned digests below).
    // 3.1415927 is the float32 nearest π (0x40490fdb); Swift's `Float.pi` is the one below it (0x40490fda), so not used.
    private let sixPixels: [Float] = [1.0, -2.5, 0.0, 3.1415927, 1e-30, 16_777_216.0]
    private let sixDigest = "9bf194d3a355bce9e41c6bfb81168ca5ffba829694d5d46ff3b3f3aa363dc8be"

    func testTheFingerprintIsSHA256OverTheFloat32BytesLittleEndianRowMajor() {
        XCTAssertEqual(SessionSourceIdentity.fingerprint(of: sixPixels), sixDigest)
        XCTAssertEqual(SessionSourceIdentity.fingerprint(of: [0, 1, 2, 3]), "4c9c4f354e74153db012329d71c8562ec23e498148174b2c49de58f45d47cdbe")
        XCTAssertEqual(SessionSourceIdentity.fingerprint(of: []), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // Row-major as stored: the order of the values is the order of the bytes, the shape is not hashed here.
        XCTAssertNotEqual(SessionSourceIdentity.fingerprint(of: [1, 2]), SessionSourceIdentity.fingerprint(of: [2, 1]))
        XCTAssertEqual(SessionSourceIdentity.of(image(sixPixels, width: 3, height: 2), fileByteSize: 1).pixelSHA256, sixDigest)
        XCTAssertEqual(SessionSourceIdentity.of(image(sixPixels, width: 2, height: 3), fileByteSize: 1).pixelSHA256, sixDigest)
    }

    func testTheFingerprintChangesWithOnePixel() {
        let pixels = (0..<24).map { Float($0) * 0.37 - 3 }
        let base = SessionSourceIdentity.fingerprint(of: pixels)
        var seen: Set<String> = [base]
        for index in pixels.indices {
            var changed = pixels
            changed[index] = Float(bitPattern: pixels[index].bitPattern ^ 1)   // one unit in the last place
            let digest = SessionSourceIdentity.fingerprint(of: changed)
            XCTAssertNotEqual(digest, base, "pixel \(index)")
            seen.insert(digest)
        }
        XCTAssertEqual(seen.count, pixels.count + 1)
        // It hashes bits: +0 and −0, and a NaN, are not the pixel they replace.
        XCTAssertNotEqual(SessionSourceIdentity.fingerprint(of: [0, 1]), SessionSourceIdentity.fingerprint(of: [-0.0, 1]))
        XCTAssertNotEqual(SessionSourceIdentity.fingerprint(of: [0, 1]), SessionSourceIdentity.fingerprint(of: [.nan, 1]))
    }

    func testTwoNaNPayloadsAreTwoImages() {
        // The doc says it hashes bits: two NaN payloads, and the sign bit of one, are three different images.
        let a = SessionSourceIdentity.fingerprint(of: [Float(bitPattern: 0x7FC0_0001)])
        let b = SessionSourceIdentity.fingerprint(of: [Float(bitPattern: 0x7FC0_0002)])
        let c = SessionSourceIdentity.fingerprint(of: [Float(bitPattern: 0xFFC0_0001)])
        XCTAssertEqual(Set([a, b, c]).count, 3)
    }

    func testTheFingerprintIsOfTheOpenedPixelsNotTheDisplayCanvas() {
        // The display canvas normalises the finite range onto [0, 1]. These two images draw the same canvas and are
        // not the same image: a fingerprint of the canvas could not tell them apart.
        let a: [Float] = [0, 10, 20, 40]
        let b: [Float] = [5, 25, 45, 85]   // 2a + 5
        func canvas(_ pixels: [Float]) -> [Float] {
            let low = pixels.min()!, high = pixels.max()!
            return pixels.map { ($0 - low) / (high - low) }
        }
        XCTAssertEqual(canvas(a), canvas(b))
        XCTAssertNotEqual(SessionSourceIdentity.fingerprint(of: a), SessionSourceIdentity.fingerprint(of: b))
        XCTAssertNotEqual(SessionSourceIdentity.of(image(a, width: 2, height: 2), fileByteSize: 1).pixelSHA256,
                          SessionSourceIdentity.of(image(b, width: 2, height: 2), fileByteSize: 1).pixelSHA256)
        // And nothing but the pixels moves it: not the calibration, the name, the object, the voltage or the notes.
        let plain = SessionSourceIdentity.of(image(a, width: 2, height: 2), fileByteSize: 1)
        let described = SessionSourceIdentity.of(
            image(a, width: 2, height: 2, fileName: "other.tif", source: "frame 1 of 3",
                  x: AxisCalibration(scale: 0.5, unit: "nm", origin: 1), y: AxisCalibration(scale: 0.7, unit: "nm", origin: 2),
                  voltage: 200_000, notes: ["8-bit render"]), fileByteSize: 99)
        XCTAssertEqual(plain.pixelSHA256, described.pixelSHA256)
    }

    func testTheIdentityOfAnImage() {
        let identity = SessionSourceIdentity.of(
            image(sixPixels, width: 3, height: 2, fileName: "scan.dm4", source: "ImageList.2 · HAADF"), fileByteSize: 12_345)
        XCTAssertEqual(identity, SessionSourceIdentity(fileName: "scan.dm4", byteSize: 12_345, object: "ImageList.2 · HAADF",
                                                       width: 3, height: 2, pixelSHA256: sixDigest))
        XCTAssertEqual(identity.width, 3)
        XCTAssertEqual(identity.height, 2)
    }

    func testTheIdentityJSONIsCanonicalAndRoundTrips() throws {
        let identity = SessionSourceIdentity(fileName: "scan.dm4", byteSize: 12_345, object: "ImageList.2 · HAADF", width: 3,
                                             height: 2, pixelSHA256: sixDigest)
        let golden = #"{"byte_size":12345,"file_name":"scan.dm4","height":2,"object":"ImageList.2 · HAADF","pixel_sha256":"\#(sixDigest)","width":3}"#
        XCTAssertEqual(try identity.jsonString(), golden)
        XCTAssertEqual(try SessionSourceIdentity.decode(golden), identity)
        XCTAssertEqual(try SessionSourceIdentity.decode(golden).jsonString(), golden)
        // A path-free name with the units' characters in it round trips too.
        let angstrom = SessionSourceIdentity(fileName: "Å µ.emd", byteSize: 0, object: "", width: 1, height: 1, pixelSHA256: sixDigest)
        XCTAssertEqual(try SessionSourceIdentity.decode(try angstrom.jsonString()), angstrom)
    }

    func testAFileNameIsStoredAndWrittenUnderNFC() throws {
        let nfc = "Å.dm4"                                  // U+00C5
        let nfd = "A\u{30A}.dm4"                           // A + combining ring
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }
        let fromInit = SessionSourceIdentity(fileName: nfd, byteSize: 1, object: "", width: 1, height: 1, pixelSHA256: sixDigest)
        XCTAssertEqual(scalars(fromInit.fileName), scalars(nfc))
        let fromImage = SessionSourceIdentity.of(image([0], width: 1, height: 1, fileName: nfd), fileByteSize: 1)
        XCTAssertEqual(scalars(fromImage.fileName), scalars(nfc))
        // Written as NFC, and an NFD name in a file is read as NFC.
        let prefix: [UInt8] = Array(#"{"byte_size":1,"file_name":""#.utf8) + Array(nfc.utf8)
        XCTAssertTrue(try fromInit.jsonString().utf8.starts(with: prefix))
        let written = try fromInit.jsonString().replacingOccurrences(of: nfc, with: nfd)
        XCTAssertTrue(written.unicodeScalars.contains("\u{30A}"), "the planted file holds the NFD name")
        XCTAssertEqual(scalars(try SessionSourceIdentity.decode(written).fileName), scalars(nfc))
    }

    func testAnIdentityThatCannotBeHeldIsRefusedByNameOnReadAndOnWrite() throws {
        let sha = sixDigest
        func json(width: Int = 3, height: Int = 2, size: Int = 1, digest: String? = nil) -> String {
            #"{"byte_size":\#(size),"file_name":"a.dm4","height":\#(height),"object":"o","pixel_sha256":"\#(digest ?? sha)","width":\#(width)}"#
        }
        XCTAssertNil(identityRefusal(json()))
        XCTAssertEqual(identityRefusal(json(width: 0)), .invalid(field: "width"))
        XCTAssertEqual(identityRefusal(json(width: -3)), .invalid(field: "width"))
        XCTAssertEqual(identityRefusal(json(height: 0)), .invalid(field: "height"))
        XCTAssertEqual(identityRefusal(json(size: -1)), .invalid(field: "byte_size"))
        XCTAssertEqual(identityRefusal(json(digest: sha.uppercased())), .invalid(field: "pixel_sha256"))
        XCTAssertEqual(identityRefusal(json(digest: String(sha.dropLast()))), .invalid(field: "pixel_sha256"))
        XCTAssertEqual(identityRefusal(json(digest: sha + "0")), .invalid(field: "pixel_sha256"))
        XCTAssertEqual(identityRefusal(json(digest: String(repeating: "g", count: 64))), .invalid(field: "pixel_sha256"))
        for text in ["", "{}", "[]", "nope", #"{"byte_size":1}"#, json().replacingOccurrences(of: #""width":3"#, with: #""width":"3""#),
                     json().replacingOccurrences(of: #""width":3"#, with: #""width":3.5"#)] {
            XCTAssertEqual(identityRefusal(text), .malformed, text)
        }
        let huge = json().replacingOccurrences(of: #""object":"o""#, with: #""object":"\#(String(repeating: "x", count: 70_000))""#)
        XCTAssertEqual(identityRefusal(huge), .tooLarge(bytes: huge.utf8.count))
        // The writer holds what it writes to the same checks.
        let bad = SessionSourceIdentity(fileName: "a", byteSize: 1, object: "", width: 1, height: 1, pixelSHA256: "abc")
        XCTAssertThrowsError(try bad.jsonString()) { XCTAssertEqual($0 as? SessionSourceIdentity.Refusal, .invalid(field: "pixel_sha256")) }
        let flat = SessionSourceIdentity(fileName: "a", byteSize: 1, object: "", width: 0, height: 1, pixelSHA256: sha)
        XCTAssertThrowsError(try flat.jsonString()) { XCTAssertEqual($0 as? SessionSourceIdentity.Refusal, .invalid(field: "width")) }
    }

    func testTheDigestAcceptsOnlyLowercaseHexAtTheEdgesOfEachRange() {
        // The characters either side of 0–9 and a–f ("/", ":", "`", "g"), and the uppercase of a and f, on read and on write.
        func refused(_ digit: Character) -> Bool {
            let digest = String(repeating: digit, count: 64)
            let writer = (try? identity(digest: digest).jsonString()) == nil
            let reader = identityRefusal(#"{"byte_size":1,"file_name":"a","height":1,"object":"","pixel_sha256":"\#(digest)","width":1}"#)
                == .invalid(field: "pixel_sha256")
            XCTAssertEqual(writer, reader, "\(digit)")
            return writer && reader
        }
        for bad: Character in ["/", ":", "`", "g", "@", "A", "F"] { XCTAssertTrue(refused(bad), "\(bad)") }
        for good: Character in ["0", "9", "a", "f"] { XCTAssertFalse(refused(good), "\(good)") }
    }

    func testTheIdentityTakesExactlyItsByteCap() throws {
        let cap = SessionSourceIdentity.maximumJSONBytes
        let base = #"{"byte_size":1,"file_name":"a","height":1,"object":"","pixel_sha256":"\#(sixDigest)","width":1}"#
        let atCap = base + String(repeating: " ", count: cap - base.utf8.count)
        XCTAssertEqual(atCap.utf8.count, cap)
        XCTAssertNil(identityRefusal(atCap))   // valid JSON: only the cap could refuse it
        XCTAssertEqual(identityRefusal(atCap + " "), .tooLarge(bytes: cap + 1))
    }

    // MARK: - The restore verdict

    private func identity(name: String = "scan.dm4", size: Int64 = 1000, object: String = "ImageList.1 · HAADF",
                          width: Int = 2048, height: Int = 2048, digest: String = String(repeating: "a", count: 64))
        -> SessionSourceIdentity {
        SessionSourceIdentity(fileName: name, byteSize: size, object: object, width: width, height: height, pixelSHA256: digest)
    }

    private func isRefusal(_ verdict: SessionRestoreVerdict) -> Bool {
        if case .refuse = verdict { return true }
        return false
    }

    func testTheSameImageIsAdoptedWhateverTheByteSize() {
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(), opened: identity()), .adopt)
        // A touched file (a copy, a backup restore) keeps its pixels: the byte size never decides.
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(size: 1000), opened: identity(size: 2_000_000)), .adopt)
    }

    func testOnlyTheNameDifferingIsAdoptedWithTheStoredName() {
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: "scan.dm4"), opened: identity(name: "scan copy.dm4")),
                       .adoptRenamed(from: "scan.dm4"))
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: "Å.dm4"), opened: identity(name: "B.dm4")),
                       .adoptRenamed(from: "Å.dm4"))
    }

    func testTheVerdictComparesNamesAndObjectsExactly() {
        // Only canonical equivalence (NFC) is forgiven: a case or a space is another name, and another object.
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: "Scan.dm4"), opened: identity(name: "scan.dm4")), .adoptRenamed(from: "Scan.dm4"))
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: "a.dm4"), opened: identity(name: "a.dm4 ")), .adoptRenamed(from: "a.dm4"))
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: "a.dm4"), opened: identity(name: " a.dm4")), .adoptRenamed(from: "a.dm4"))
        for (stored, opened) in [("HAADF", "haadf"), ("HAADF", "HAADF "), ("HAADF", " HAADF")] {
            XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(object: stored), opened: identity(object: opened))), "\(stored) | \(opened)")
        }
    }

    func testNFDAndNFCNamesAreTheSameName() {
        let nfc = "Å.dm4", nfd = "A\u{30A}.dm4"
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: nfc), opened: identity(name: nfd)), .adopt)
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: nfd), opened: identity(name: nfc)), .adopt)
        // The stored name a note shows is the NFC one.
        guard case .adoptRenamed(let from) = SessionRestoreVerdict.decide(stored: identity(name: nfd), opened: identity(name: "other.dm4")) else {
            return XCTFail("expected a rename")
        }
        XCTAssertEqual(from.unicodeScalars.map(\.value), nfc.unicodeScalars.map(\.value))
    }

    func testOtherPixelsOfTheSameShapeAreAdoptedFlagged() {
        let other = String(repeating: "b", count: 64)
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(), opened: identity(digest: other)), .adoptPixelsDiffer)
        // Pixels and name both: the image changing is the louder fact.
        XCTAssertEqual(SessionRestoreVerdict.decide(stored: identity(name: "a.dm4"), opened: identity(name: "b.dm4", digest: other)),
                       .adoptPixelsDiffer)
    }

    func testAnotherObjectOrShapeIsRefused() {
        let other = String(repeating: "b", count: 64)
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(), opened: identity(object: "ImageList.2 · BF"))))
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(), opened: identity(width: 1024))))
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(), opened: identity(height: 1024))))
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(width: 2048, height: 1024), opened: identity(width: 1024, height: 2048))))
        // Refused whatever the pixels: the same fingerprint of another shape (transposed, say) is still not this image,
        // and another fingerprint does not soften it.
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(width: 2048, height: 1024), opened: identity(width: 1024, height: 2048))))
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(), opened: identity(object: "ImageList.2 · BF", digest: other))))
        XCTAssertTrue(isRefusal(SessionRestoreVerdict.decide(stored: identity(), opened: identity(width: 512, digest: other))))
        // The sentence names both images.
        guard case .refuse(let reason) = SessionRestoreVerdict.decide(
            stored: identity(object: "ImageList.1 · HAADF", width: 2048, height: 2048),
            opened: identity(object: "ImageList.2 · BF", width: 1024, height: 512)) else { return XCTFail("expected a refusal") }
        for part in ["ImageList.1 · HAADF", "2048 × 2048", "ImageList.2 · BF", "1024 × 512"] {
            XCTAssertTrue(reason.contains(part), "\(part) in \(reason)")
        }
    }
}
