//
//  SessionLineage.swift
//  Role: the session sidecar's records as pure data and pure rules (archive: roadmap-registrations-2026-10-15.md V1-2, slice A; ADR 020, adapted from
//        mac4DSTEM's ADR 047): the lineage — one node per completed measurement on the opened image — with its
//        canonical JSON and the guards that read it; the identity of the image a sidecar describes; and the verdict
//        that decides, before anything is adopted, whether a sidecar belongs to the image just opened. No HDF5, no
//        file, no SwiftUI, no AppState: `SessionSidecarFile` stores the two JSON strings these types produce and
//        parses.
//
//  WRITTEN FRESH from the ADRs, not copied from mac4DSTEM's `SessionLineage` (that one's nodes are 4D runs with
//  replay, rewind, frames and products; macTEM's are marks). DEVIATIONS from ADR 047, each ADR 020's:
//    - `recorded` is integer milliseconds since 1970 (047: Double seconds), quantised when recorded, so a re-read is
//      EQUAL, not "within a millisecond".
//    - Removing a node DELETES it (047 R4: nothing deleted, for hour-long runs behind a rewind). A node another node
//      cites is kept with a `removed` date, and goes when its last citer does.
//    - An unknown lineage `version` is a read-only lineage with no nodes (047: "read as v1"; macTEM has no v1).
//    - No replay record, no `head`, no `frame`, no `product`.
//
//  THE FORMAT (one root attribute, a fixed-length UTF-8 string: ADR 021): sorted keys, every number an integer, every
//  coordinate or measurement a STRING (Swift's shortest round-trip `Double.description`, parsed back bit-exact by
//  `coordinate(from:)`), so no float is ever re-rounded by a JSON layer on the way through h5py or back. Byte-stable on
//  re-encode.
//    {"next_id":2,"nodes":[{"external":[],"id":"s1","inputs":[],"kind":"distance",
//      "parameters":{"x1":"10.5","x2":"40.25","y1":"20.0","y2":"20.0"},"recorded":1791900000123,
//      "results":{"length":"29.75","unit":"nm"}}],"version":1}
//  A node is written with `external`, `id`, `inputs`, `kind`, `parameters`, `recorded`, `results` always and
//  `removed` only when set. The reader requires `version`, `next_id`, `nodes` and each node's `id`, `kind`,
//  `recorded`; an absent `parameters`, `results`, `inputs` or `external` is empty; unknown keys are ignored.
//
//  THE GUARDS (R8), each a named `Refusal`, never a partial graph: over 4 MiB of UTF-8, not JSON or the wrong shape,
//  more than 2 000 nodes, `next_id` outside 1…1 000 000, an id not `s` + a decimal 1…1 000 000 without leading zeros,
//  a repeated id, an id at or above `next_id`, an input naming a missing node, a cycle. An unknown `kind` is kept
//  opaque. (`add` also refuses an input naming a removed node; the reader accepts a live node citing one, which is
//  how a kept node is written.) THE WRITER runs the same checks on what it writes and reads its own output back: a
//  sidecar this build writes is one this build reads.
//
//  THE RESTORE VERDICT: `SessionSourceIdentity` is what `mactem_source` holds (file name under NFC, byte size for
//  diagnosis only, the opened object's `source`, width × height, and a SHA-256 of the opened Float32 pixels — the
//  file's own `CalibratedImage`, never the display canvas); `SessionRestoreVerdict.decide` is pure.
//

import CryptoKit
import Foundation

/// The recorded marks of one session on one image. Serialized as one JSON root attribute (`mactem_lineage`).
package nonisolated struct SessionLineage: Sendable, Equatable {

    // MARK: - Limits (R8)

    /// The one lineage version this build reads and writes.
    package static let version = 1
    /// The reader's length cap, in UTF-8 bytes, and the writer's.
    package static let maximumJSONBytes = 4 * 1024 * 1024
    package static let maximumNodes = 2000
    /// The bound on `next_id`, and the recorder's on minting: `add` mints only while `nextID` is below it, so the
    /// value a file carries after any mint is one the reader accepts (and the highest id is `s999999`).
    package static let maximumNextID = 1_000_000

    // MARK: - Vocabulary

    /// The kinds this build records (`ImageMark.Kind.rawValue`s), and the kinds ADR 020 reserves. A kind outside
    /// both is kept as an opaque node.
    package nonisolated enum Kind {
        package static let distance = "distance"
        package static let angle = "angle"
        package static let profile = "profile"
        package static let reserved: Set<String> = ["calibration", "fft", "hrtem_filter", "export"]
    }

    /// An edge to a node this one consumed. A mark reads only the source image and has none.
    package nonisolated struct Edge: Codable, Equatable, Sendable {
        package var step: String
        package var role: String

        package init(step: String, role: String) {
            self.step = step
            self.role = role
        }
    }

    /// An input from outside the session (reserved, V1-8's CIF): a name and a content fingerprint, never an
    /// absolute path — the repo is public and sidecars travel.
    package nonisolated struct External: Codable, Equatable, Sendable {
        package var name: String
        package var fingerprint: String

        package init(name: String, fingerprint: String) {
            self.name = name
            self.fingerprint = fingerprint
        }
    }

    /// One completed measurement.
    package nonisolated struct Node: Codable, Equatable, Sendable {
        /// `s1`, `s2`, … from `next_id`, never reused.
        package var id: String
        package var kind: String
        /// Flat string → string: what the measurement took (points as `coordinateString`s, a width, the opened
        /// `object` and `frame`).
        package var parameters: [String: String]
        /// The values shown (length and unit, angle, sample count) and the scales used. Recomputed at open, never
        /// trusted over the pixels.
        package var results: [String: String]
        package var inputs: [Edge]
        package var external: [External]
        /// Milliseconds since 1970, quantised by `milliseconds(_:)` when recorded.
        package var recorded: Int64
        /// Set only on a node the user removed that another node still cites; nil on every live node.
        package var removed: Int64?

        package init(id: String, kind: String, parameters: [String: String], results: [String: String] = [:],
                     inputs: [Edge] = [], external: [External] = [], recorded: Int64, removed: Int64? = nil) {
            self.id = id
            self.kind = kind
            self.parameters = parameters
            self.results = results
            self.inputs = inputs
            self.external = external
            self.recorded = recorded
            self.removed = removed
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, parameters, results, inputs, external, recorded, removed
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            kind = try container.decode(String.self, forKey: .kind)
            parameters = try container.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
            results = try container.decodeIfPresent([String: String].self, forKey: .results) ?? [:]
            inputs = try container.decodeIfPresent([Edge].self, forKey: .inputs) ?? []
            external = try container.decodeIfPresent([External].self, forKey: .external) ?? []
            recorded = try container.decode(Int64.self, forKey: .recorded)
            removed = try container.decodeIfPresent(Int64.self, forKey: .removed)
        }
    }

    // MARK: - State

    /// The next id to hand out. Never decreases, so an id is never reused (a delete does not give one back).
    package private(set) var nextID: Int = 1
    /// In id order (ids are minted ascending and only ever deleted).
    package private(set) var nodes: [Node] = []
    /// The version the JSON said. Not `version` only when `isReadOnly`.
    package private(set) var fileVersion: Int = SessionLineage.version

    /// A lineage written by a newer build: carries no nodes (its shape is not this build's to interpret), refuses to
    /// be mutated and to be written, so the caller can never rewrite over it.
    package var isReadOnly: Bool { fileVersion != Self.version }

    /// The nodes the user has not removed.
    package var liveNodes: [Node] { nodes.filter { $0.removed == nil } }

    package init() {}

    package func node(id: String) -> Node? { nodes.first { $0.id == id } }

    // MARK: - Why it was refused

    /// Why the reader refused a lineage, or the writer a write or a mint. The reason is the sentence.
    package nonisolated enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case tooLarge(bytes: Int)
        case malformed
        case tooManyNodes(Int)
        case badNextID(Int)
        case badID(String)
        case duplicateID(String)
        case idNotBelowNextID(id: String, nextID: Int)
        case danglingInput(step: String, from: String)
        case cycle
        /// Writer and `add` only: a lineage from a newer version is never rewritten or extended.
        case unsupportedVersion(Int)
        /// `add` only: every id up to the bound has been minted.
        case idsExhausted
        /// The owner only (ADR 023 a): the record, saved, would be `bytes` of text, over the `limit` a sidecar may hold.
        case tooLargeToSave(bytes: Int, limit: Int)
        /// The owner only: a mark's point is not a finite number, so it is not a place on the image.
        case notFinite

        package var reason: String {
            switch self {
            case .tooLarge(let bytes):
                "the lineage is \(bytes) bytes, over the \(SessionLineage.maximumJSONBytes)-byte cap"
            case .malformed:
                "the lineage is not a lineage object (not JSON, or the wrong shape)"
            case .tooManyNodes(let count):
                "the lineage has \(count) nodes, over the \(SessionLineage.maximumNodes)-node cap"
            case .badNextID(let nextID):
                "next_id \(nextID) is outside 1…\(SessionLineage.maximumNextID)"
            case .badID(let id):
                "the node id \"\(id)\" is not s followed by a number from 1 to \(SessionLineage.maximumNextID)"
            case .duplicateID(let id):
                "the node id \(id) appears twice"
            case .idNotBelowNextID(let id, let nextID):
                "the node id \(id) is not below next_id \(nextID)"
            case .danglingInput(let step, let from):
                "node \(from) consumes \(step), which is not a node"
            case .cycle:
                "the lineage has a cycle"
            case .unsupportedVersion(let version):
                "the lineage is version \(version), newer than this build reads (\(SessionLineage.version)); it is never rewritten"
            case .idsExhausted:
                "every node id up to s\(SessionLineage.maximumNextID - 1) has been used"
            case .tooLargeToSave(let bytes, let limit):
                "the session record would be \(bytes) bytes of text, over the \(limit) a session file holds; remove some marks"
            case .notFinite:
                "a point of the mark is not a finite number"
            }
        }

        package var description: String { reason }
    }

    // MARK: - Time and coordinates

    /// Milliseconds since 1970, rounded to the nearest (a tie goes away from zero): the one place a date becomes a
    /// number, so `recorded` is integer on disk and a re-read is exactly equal. Idempotent through
    /// `date(milliseconds:)` for every |ms| ≤ 4e15 (year ±127 000): a Double date there carries the millisecond with
    /// under half a millisecond of rounding, so a re-quantised value is the same one. Beyond about 4.4e15 the rounding
    /// can reach half a millisecond and a value may move by one. A date no millisecond count within ±9e15 can hold is
    /// clamped to ±9e15 (that keeps the Int64 conversion defined; it is not the idempotence bound); NaN is 0.
    package static func milliseconds(_ date: Date) -> Int64 {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        guard !ms.isNaN else { return 0 }
        return Int64(min(max(ms, -9e15), 9e15))
    }

    package static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// A coordinate (or any measured value) as a string: Swift's shortest round-trip `description`, "0.1", "1e-300",
    /// "-0.0", "16777217.5". Coordinates are finite by construction (a point on the image).
    package static func coordinateString(_ value: Double) -> String { value.description }

    /// The value `coordinateString` wrote, bit-exact, or nil for text that is not a finite number.
    package static func coordinate(from string: String) -> Double? {
        guard let value = Double(string), value.isFinite else { return nil }
        return value
    }

    // MARK: - Recording

    /// Why `add` would refuse any node now — a read-only lineage, 2 000 nodes (removed and other kinds count), or every
    /// id spent — or nil. What a tool asks before a gesture (archive: roadmap-registrations-2026-10-15.md V1-2 slice B: `recordingRefusal`).
    package var mintRefusal: Refusal? {
        if isReadOnly { return .unsupportedVersion(fileVersion) }
        if nodes.count >= Self.maximumNodes { return .tooManyNodes(nodes.count + 1) }
        if nextID >= Self.maximumNextID { return .idsExhausted }
        return nil
    }

    /// One measurement completed on the opened image. Returns the id of the new node (`s<nextID>`); an id is never
    /// reused. Throws, changing nothing, when the lineage is read-only, full (2 000 nodes, or every id spent), or an
    /// input names a missing or a removed node (a removed node stays only for the nodes that already cite it).
    @discardableResult
    package mutating func add(
        kind: String, parameters: [String: String], results: [String: String] = [:], inputs: [Edge] = [],
        recorded: Int64 = SessionLineage.milliseconds(Date())
    ) throws(Refusal) -> String {
        if let refusal = mintRefusal { throw refusal }
        let id = "s\(nextID)"
        for edge in inputs {
            guard let input = node(id: edge.step), input.removed == nil else { throw .danglingInput(step: edge.step, from: id) }
        }
        nextID += 1   // < maximumNextID, so this cannot overflow
        nodes.append(Node(id: id, kind: kind, parameters: parameters, results: results, inputs: inputs,
                          recorded: recorded))
        return id
    }

    /// R3: the mark moved or its width changed — its parameters and results are replaced IN PLACE (same id, same
    /// position, same kind and inputs), `recorded` is the new time. False, changing nothing, for an unknown id, a node
    /// that was removed, or a read-only lineage (which has no nodes: the guard is defence in depth).
    @discardableResult
    package mutating func replace(
        id: String, parameters: [String: String], results: [String: String],
        recorded: Int64 = SessionLineage.milliseconds(Date())
    ) -> Bool {
        guard !isReadOnly, let index = nodes.firstIndex(where: { $0.id == id }), nodes[index].removed == nil else { return false }
        nodes[index].parameters = parameters
        nodes[index].results = results
        nodes[index].recorded = recorded
        return true
    }

    /// What `remove` did.
    package nonisolated enum Removal: Equatable, Sendable {
        /// The node is gone (ids are not given back).
        case deleted
        /// Another node cites it, so it stays, with a `removed` date, until its last citer goes.
        case kept
        /// No such node.
        case absent
    }

    /// ADR 020: removing a mark DELETES its node, unless another node's inputs cite it (a future `export`) — then it
    /// gets `removed` and stays, for the citer's sake. A kept node whose last citer is deleted goes with it, and so
    /// does every removed node only it cited, so an exploratory mark is never carried with the data for good. A
    /// read-only lineage (no nodes) answers `.absent` and changes nothing.
    @discardableResult
    package mutating func remove(id: String, at removed: Int64 = SessionLineage.milliseconds(Date())) -> Removal {
        guard !isReadOnly, let index = nodes.firstIndex(where: { $0.id == id }) else { return .absent }
        if isCited(id) {
            if nodes[index].removed == nil { nodes[index].removed = removed }
            return .kept
        }
        nodes.remove(at: index)
        sweepOrphans()
        return .deleted
    }

    /// Delete every removed node that no remaining node cites, and, as each goes, the removed nodes only it cited:
    /// one pass over the edges (a citation count and a work list), not a rescan of every node per deletion (a planted
    /// chain of 2 000 removed nodes cost 19 s that way). The lookups cannot miss: ids are unique and every input
    /// resolves (both checked by `validate`, which every lineage passed on its way in), and each edge is counted below.
    private mutating func sweepOrphans() {
        var citations: [String: Int] = [:]
        for node in nodes { for edge in node.inputs { citations[edge.step, default: 0] += 1 } }
        var position: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() { position[node.id] = offset }
        var work = nodes.filter { $0.removed != nil && citations[$0.id] == nil }.map(\.id)
        var doomed = Set<String>()
        while let id = work.popLast() {
            doomed.insert(id)
            for edge in nodes[position[id]!].inputs {
                citations[edge.step]! -= 1
                if citations[edge.step] == 0, let at = position[edge.step], nodes[at].removed != nil { work.append(edge.step) }
            }
        }
        nodes.removeAll { doomed.contains($0.id) }
    }

    private func isCited(_ id: String) -> Bool {
        nodes.contains { node in node.inputs.contains { $0.step == id } }
    }

    // MARK: - The guards

    /// The number in an id of the form `s<n>`, n in 1…`maximumNextID` as plain decimal digits (no sign, no leading
    /// zero, no other character), or nil.
    package static func number(ofID id: String) -> Int? {
        let digits = id.utf8.dropFirst()
        guard id.utf8.first == UInt8(ascii: "s"), !digits.isEmpty, digits.count <= 7,
              digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              digits.first != UInt8(ascii: "0"),
              let number = Int(id.dropFirst()), number >= 1, number <= maximumNextID else { return nil }
        return number
    }

    /// Every check on an in-memory lineage that is not the byte cap or the JSON shape. The reader's and the writer's.
    private func validate() throws(Refusal) {
        guard nodes.count <= Self.maximumNodes else { throw .tooManyNodes(nodes.count) }
        guard nextID >= 1, nextID <= Self.maximumNextID else { throw .badNextID(nextID) }
        var seen = Set<String>()
        for node in nodes {
            guard let number = Self.number(ofID: node.id) else { throw .badID(node.id) }
            guard seen.insert(node.id).inserted else { throw .duplicateID(node.id) }
            guard number < nextID else { throw .idNotBelowNextID(id: node.id, nextID: nextID) }
        }
        for node in nodes {
            for edge in node.inputs where !seen.contains(edge.step) {
                throw .danglingInput(step: edge.step, from: node.id)
            }
        }
        guard !hasCycle() else { throw .cycle }
    }

    /// Kahn's algorithm over the input edges (a node citing itself never resolves).
    private func hasCycle() -> Bool {
        var remaining: [String: Int] = [:]          // unresolved inputs per node
        var consumers: [String: [String]] = [:]     // input id -> nodes that consume it
        for node in nodes {
            remaining[node.id] = node.inputs.count
            for edge in node.inputs { consumers[edge.step, default: []].append(node.id) }
        }
        var ready = remaining.filter { $0.value == 0 }.map(\.key)
        var resolved = 0
        while let id = ready.popLast() {
            resolved += 1
            for consumer in consumers[id] ?? [] {
                remaining[consumer, default: 0] -= 1
                if remaining[consumer] == 0 { ready.append(consumer) }
            }
        }
        return resolved != nodes.count
    }

    // MARK: - Serialization

    private struct Wire: Codable {
        var version: Int
        var nextID: Int
        var nodes: [Node]

        private enum CodingKeys: String, CodingKey {
            case version, nodes
            case nextID = "next_id"
        }
    }

    /// The canonical JSON: sorted keys, integer numbers, byte-stable on re-encode. The writer checks what it writes
    /// as the reader does and reads its own output back; a lineage from a newer version is never written.
    package func jsonString() throws(Refusal) -> String {
        guard !isReadOnly else { throw .unsupportedVersion(fileVersion) }
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // try? OK: strings, integers and string dictionaries have no encoding failure; nil is `.malformed`, which
        // the caller turns into "nothing written".
        guard let data = try? encoder.encode(Wire(version: Self.version, nextID: nextID, nodes: nodes)),
              let json = String(data: data, encoding: .utf8) else { throw .malformed }
        guard try Self.decode(json) == self else { throw .malformed }
        return json
    }

    /// Decode and validate. Never a partial graph: the first failed check refuses. A `version` this build does not
    /// know is NOT a refusal: it returns a read-only lineage (no nodes), so the file is read for the rest of what it
    /// holds and never rewritten over.
    package static func decode(_ json: String) throws(Refusal) -> SessionLineage {
        let byteCount = json.utf8.count
        guard byteCount <= maximumJSONBytes else { throw .tooLarge(bytes: byteCount) }
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        // The version first, from a probe that reads nothing else: a newer version may reshape its nodes, and must be
        // recognised as NEWER, not refused as malformed.
        struct VersionProbe: Decodable { let version: Int }
        // try? OK: any decoding failure is the one named refusal, `.malformed`.
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { throw .malformed }
        guard probe.version == version else {
            var readOnly = SessionLineage()
            readOnly.fileVersion = probe.version
            return readOnly
        }
        guard let wire = try? decoder.decode(Wire.self, from: data) else { throw .malformed }
        var lineage = SessionLineage()
        lineage.nextID = wire.nextID
        lineage.nodes = wire.nodes
        try lineage.validate()
        return lineage
    }
}

// MARK: - The identity of the image a sidecar describes

/// What `mactem_source` holds. A sidecar belongs to the image it was drawn on; this is how that is known.
package nonisolated struct SessionSourceIdentity: Sendable, Equatable, Codable {

    /// The reader's length cap for the attribute, in UTF-8 bytes (a file name is ≤ 255 bytes).
    package static let maximumJSONBytes = 64 * 1024

    /// The file's name, never its folders, under Unicode NFC (macOS can hand back NFD; "Å" is common in EM file
    /// names): stored, compared and written as NFC.
    package let fileName: String
    /// The file's size on disk. Diagnostic only: it never decides a verdict (a touched file keeps its pixels).
    package let byteSize: Int64
    /// `CalibratedImage.source`: which object of a multi-object file this is ("ImageList.2 · HAADF").
    package let object: String
    package let width: Int
    package let height: Int
    /// Lowercase hex SHA-256 of the opened image's Float32 pixels (`fingerprint(of:)`).
    package let pixelSHA256: String

    package init(fileName: String, byteSize: Int64, object: String, width: Int, height: Int, pixelSHA256: String) {
        self.fileName = fileName.precomposedStringWithCanonicalMapping
        self.byteSize = byteSize
        self.object = object
        self.width = width
        self.height = height
        self.pixelSHA256 = pixelSHA256
    }

    /// The identity of an opened image: its file name, its object, its shape and the fingerprint of its own pixels
    /// (`image.pixels` — the file's values, never the display canvas, which a contrast setting and a normalisation
    /// would change without the image changing).
    package static func of(_ image: CalibratedImage, fileByteSize: Int64) -> SessionSourceIdentity {
        SessionSourceIdentity(fileName: image.fileName, byteSize: fileByteSize, object: image.source,
                              width: image.width, height: image.height, pixelSHA256: fingerprint(of: image.pixels))
    }

    /// Lowercase hex SHA-256 over the pixels' bytes: Float32, IEEE-754 little-endian, row-major as stored. It
    /// hashes bits, not values (+0 and −0 differ; so do two NaN payloads), which is what "the same file" means.
    package static func fingerprint(of pixels: [Float]) -> String {
        var hasher = SHA256()
        #if _endian(little)
        pixels.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        #else
        var chunk = [UInt32](repeating: 0, count: 16 * 1024)
        var start = 0
        while start < pixels.count {
            let count = min(chunk.count, pixels.count - start)
            for i in 0..<count { chunk[i] = pixels[start + i].bitPattern.littleEndian }
            chunk.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<(count * 4)])) }
            start += count
        }
        #endif
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Serialization

    private enum CodingKeys: String, CodingKey {
        case fileName = "file_name", byteSize = "byte_size", object, width, height, pixelSHA256 = "pixel_sha256"
    }

    /// Decoding goes through `init`, so a name written as NFD is read as NFC.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fileName: try container.decode(String.self, forKey: .fileName),
                  byteSize: try container.decode(Int64.self, forKey: .byteSize),
                  object: try container.decode(String.self, forKey: .object),
                  width: try container.decode(Int.self, forKey: .width),
                  height: try container.decode(Int.self, forKey: .height),
                  pixelSHA256: try container.decode(String.self, forKey: .pixelSHA256))
    }

    package nonisolated enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case tooLarge(bytes: Int)
        case malformed
        /// The JSON is the right shape but a value is not one an identity can hold.
        case invalid(field: String)

        package var reason: String {
            switch self {
            case .tooLarge(let bytes):
                "the source identity is \(bytes) bytes, over the \(SessionSourceIdentity.maximumJSONBytes)-byte cap"
            case .malformed:
                "the source identity is not an identity object (not JSON, or the wrong shape)"
            case .invalid(let field):
                "the source identity's \(field) is not a valid value"
            }
        }

        package var description: String { reason }
    }

    /// A shape of at least one pixel, a size that is not negative, and a fingerprint of 64 lowercase hex digits.
    private func validate() throws(Refusal) {
        guard width >= 1 else { throw .invalid(field: "width") }
        guard height >= 1 else { throw .invalid(field: "height") }
        guard byteSize >= 0 else { throw .invalid(field: "byte_size") }
        guard pixelSHA256.utf8.count == 64,
              pixelSHA256.utf8.allSatisfy({ ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                                            || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) })
        else { throw .invalid(field: "pixel_sha256") }
    }

    /// The canonical JSON (sorted keys, integers), validated as the reader validates and read back.
    package func jsonString() throws(Refusal) -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // try? OK: strings and integers have no encoding failure; nil is `.malformed` (nothing written).
        guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) else {
            throw .malformed
        }
        guard try Self.decode(json) == self else { throw .malformed }
        return json
    }

    package static func decode(_ json: String) throws(Refusal) -> SessionSourceIdentity {
        let byteCount = json.utf8.count
        guard byteCount <= maximumJSONBytes else { throw .tooLarge(bytes: byteCount) }
        // try? OK: any decoding failure is the one named refusal, `.malformed`.
        guard let identity = try? JSONDecoder().decode(SessionSourceIdentity.self, from: Data(json.utf8)) else {
            throw .malformed
        }
        try identity.validate()
        return identity
    }
}

// MARK: - The restore verdict

/// What to do with a sidecar once the image it describes (`stored`) and the image just opened (`opened`) are
/// compared. Pure: decided before anything is adopted.
package nonisolated enum SessionRestoreVerdict: Equatable, Sendable {
    /// The same image: restore the marks.
    case adopt
    /// The same image under another name: restore, noting the stored name.
    case adoptRenamed(from: String)
    /// The same object and shape, other pixels: restore, flagged "the image differs from when the marks were drawn".
    case adoptPixelsDiffer
    /// Another object or shape: the marks cannot belong to this image. Refused whole; saves to this sidecar are off.
    /// The associated value is the sentence.
    case refuse(String)

    /// The object or the width × height differs → `.refuse`; the same shape with other pixels → `.adoptPixelsDiffer`
    /// (before a rename: the image changing is the louder fact); only the name differs (NFC) → `.adoptRenamed`;
    /// else `.adopt`. The byte size never decides.
    package static func decide(stored: SessionSourceIdentity, opened: SessionSourceIdentity) -> SessionRestoreVerdict {
        guard stored.object == opened.object, stored.width == opened.width, stored.height == opened.height else {
            return .refuse("The marks were drawn on \(describe(stored)); this file opened as \(describe(opened)).")
        }
        if stored.pixelSHA256 != opened.pixelSHA256 { return .adoptPixelsDiffer }
        if stored.fileName != opened.fileName { return .adoptRenamed(from: stored.fileName) }
        return .adopt
    }

    private static func describe(_ identity: SessionSourceIdentity) -> String {
        let shape = "\(identity.width) × \(identity.height) pixels"
        return identity.object.isEmpty ? shape : "“\(identity.object)”, \(shape)"
    }
}
