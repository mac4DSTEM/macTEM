//
//  SEMParityReference.swift
//  The Swift side of tools/parity/sem: a reference bundle (manifest.json plus raw little-endian arrays, written by
//  tools/parity/sem/emit.py from the pinned kikuchipy / orix / HyperSpy / exspy / RosettaSciIO stack) loaded for a parity
//  test, and the comparison every SEM port is held to: numpy's assert_allclose rule, |a - b| <= atol + rtol * |b|, with the
//  reference as b and the tolerance the bundle states (0/0 is exact). A port's test loads its case by name, runs the Swift
//  function on the same fixture (`inputs`) and compares; nothing here makes a number.
//
//  Layout (tools/parity/sem/lib/refbundle.py is the writer and the schema's owner):
//    references/<milestone>/<case>/manifest.json   schema 1: reference package and version, stack, inputs with sha256,
//                                                  values (exact JSON), scalars (value, rtol, atol), arrays (file, dtype,
//                                                  shape, sha256, rtol, atol)
//    references/<milestone>/<case>/<name>.bin      C order, little-endian, no header; uint8 uint16 int32 int64 float32 float64
//

import CryptoKit
import Foundation
import XCTest

/// One committed reference case.
nonisolated struct SEMParityReference {
    struct ArrayEntry: Decodable, Sendable {
        let file: String
        let dtype: String
        let shape: [Int]
        let sha256: String
        let rtol: Double
        let atol: Double
        let note: String?
        var count: Int { shape.reduce(1, *) }
        var isExact: Bool { rtol == 0 && atol == 0 }
    }

    struct ScalarEntry: Decodable, Sendable {
        let value: Double
        let rtol: Double
        let atol: Double
    }

    struct Input: Decodable, Sendable {
        let path: String
        let sha256: String
    }

    struct Manifest: Decodable, Sendable {
        struct Package: Decodable, Sendable {
            let package: String
            let version: String
            let function: String
        }

        let schema: Int
        let caseName: String
        let milestone: Int
        let reference: Package
        let stack: [String: String?]
        let inputs: [Input]
        let scalars: [String: ScalarEntry]
        let arrays: [String: ArrayEntry]
        // `values` is free-form JSON: read it as `[String: Any]` through `SEMParityReference.values`.

        enum CodingKeys: String, CodingKey {
            case schema, milestone, reference, stack, inputs, scalars, arrays
            case caseName = "case"
        }
    }

    /// A loaded array: its shape (row-major) and its elements widened to Double (every dtype the writer allows is exact in
    /// Double except int64 beyond 2^53, which no bundle holds; a loader that needs the raw bytes reads `rawData`).
    struct LoadedArray: Sendable {
        let name: String
        let shape: [Int]
        let dtype: String
        let values: [Double]
        let rtol: Double
        let atol: Double
    }

    let directory: URL
    let manifest: Manifest
    let values: [String: Any]

    /// tools/parity/sem relative to this file: macTEMTests/ and tools/ are siblings under the repo root.
    static var harnessRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/parity/sem", isDirectory: true)
    }

    static var referencesRoot: URL { harnessRoot.appendingPathComponent("references", isDirectory: true) }
    static var fixturesRoot: URL { harnessRoot.appendingPathComponent("fixtures", isDirectory: true) }

    /// Every committed case name (`m1/read-nordif`), sorted.
    static func allCases() throws -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: referencesRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in e where url.lastPathComponent == "manifest.json" {
            let dir = url.deletingLastPathComponent()
            out.append(dir.deletingLastPathComponent().lastPathComponent + "/" + dir.lastPathComponent)
        }
        return out.sorted()
    }

    static func load(_ caseName: String) throws -> SEMParityReference {
        let dir = referencesRoot.appendingPathComponent(caseName, isDirectory: true)
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schema == 1 else { throw Failure("\(caseName): manifest schema \(manifest.schema), this loader reads 1") }
        guard manifest.caseName == caseName else { throw Failure("\(caseName): manifest names case \(manifest.caseName)") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let values = json?["values"] as? [String: Any] ?? [:]
        return SEMParityReference(directory: dir, manifest: manifest, values: values)
    }

    /// The fixture an input names, as a URL under tools/parity/sem (a `sem-data/` input is a downloaded dataset under
    /// References/sem-data, absent on a machine that has not fetched it: the caller skips with `XCTSkip`).
    func inputURL(_ index: Int = 0) -> URL? {
        guard manifest.inputs.indices.contains(index) else { return nil }
        let path = manifest.inputs[index].path
        if path.hasPrefix("fixtures/") { return Self.harnessRoot.appendingPathComponent(path) }
        if path.hasPrefix("sem-data/") {
            return Self.harnessRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("References").appendingPathComponent(path)
        }
        return nil
    }

    func rawData(_ name: String) throws -> (ArrayEntry, Data) {
        guard let entry = manifest.arrays[name] else { throw Failure("\(manifest.caseName): no array \(name)") }
        let data = try Data(contentsOf: directory.appendingPathComponent(entry.file))
        return (entry, data)
    }

    /// The array by name, its bytes checked against the manifest's sha256 and count.
    func array(_ name: String) throws -> LoadedArray {
        let (entry, data) = try rawData(name)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else { throw Failure("\(manifest.caseName)/\(name): file sha256 \(digest) is not the manifest's \(entry.sha256)") }
        let values = try Self.decode(data, dtype: entry.dtype, count: entry.count, label: "\(manifest.caseName)/\(name)")
        return LoadedArray(name: name, shape: entry.shape, dtype: entry.dtype, values: values, rtol: entry.rtol, atol: entry.atol)
    }

    static func decode(_ data: Data, dtype: String, count: Int, label: String) throws -> [Double] {
        func read<T: FixedWidthInteger>(_: T.Type) throws -> [Double] {
            guard data.count == count * MemoryLayout<T>.size else { throw Failure("\(label): \(data.count) bytes for \(count) \(dtype)") }
            return data.withUnsafeBytes { raw in (0..<count).map { Double(T(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self))) } }
        }
        switch dtype {
        case "uint8": return try read(UInt8.self)
        case "uint16": return try read(UInt16.self)
        case "int32": return try read(Int32.self)
        case "int64": return try read(Int64.self)
        case "float32":
            guard data.count == count * 4 else { throw Failure("\(label): \(data.count) bytes for \(count) float32") }
            return data.withUnsafeBytes { raw in (0..<count).map { Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))) } }
        case "float64":
            guard data.count == count * 8 else { throw Failure("\(label): \(data.count) bytes for \(count) float64") }
            return data.withUnsafeBytes { raw in (0..<count).map { Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self))) } }
        default: throw Failure("\(label): dtype \(dtype) is not one this loader reads")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) {
            description = d
        }
    }
}

/// The comparison. `mismatch` returns nil when every element is within tolerance; otherwise the worst element, so a test
/// prints what moved and by how much rather than only that something did.
nonisolated enum SEMParityCompare {
    struct Mismatch: CustomStringConvertible, Sendable {
        let name: String
        let count: Int
        let total: Int
        let worstIndex: Int
        let actual: Double
        let expected: Double
        let rtol: Double
        let atol: Double
        var description: String {
            let kind = rtol == 0 && atol == 0 ? "exact" : "rtol \(rtol), atol \(atol)"
            return "\(name): \(count) of \(total) elements outside tolerance (\(kind)); worst at flat index \(worstIndex): got \(actual), reference \(expected)"
        }
    }

    /// numpy.testing.assert_allclose: |a - b| <= atol + rtol * |b|, b the reference; NaN matches NaN only.
    static func mismatch(name: String, actual: [Double], expected: [Double], rtol: Double, atol: Double) -> Mismatch? {
        guard actual.count == expected.count else {
            return Mismatch(name: name, count: max(actual.count, expected.count), total: expected.count, worstIndex: -1,
                            actual: Double(actual.count), expected: Double(expected.count), rtol: rtol, atol: atol)
        }
        var bad = 0
        var worst = -1
        var worstExcess = -Double.infinity
        for i in actual.indices {
            let a = actual[i]
            let b = expected[i]
            if a.isNaN, b.isNaN { continue }
            let excess = abs(a - b) - (atol + rtol * abs(b))
            if !(excess <= 0) {   // NaN against a number fails too
                bad += 1
                if excess > worstExcess || excess.isNaN {
                    worstExcess = excess
                    worst = i
                }
            }
        }
        guard bad > 0 else { return nil }
        return Mismatch(name: name, count: bad, total: expected.count, worstIndex: worst, actual: actual[worst], expected: expected[worst], rtol: rtol, atol: atol)
    }

    static func mismatch(actual: [Double], reference: SEMParityReference.LoadedArray) -> Mismatch? {
        mismatch(name: reference.name, actual: actual, expected: reference.values, rtol: reference.rtol, atol: reference.atol)
    }
}

/// Assert a Swift result against a reference array at the bundle's tolerance.
nonisolated func SEMAssertParity(_ actual: [Double], _ reference: SEMParityReference.LoadedArray, shape: [Int]? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
    if let shape, shape != reference.shape {
        XCTFail("\(reference.name): shape \(shape), reference \(reference.shape)", file: file, line: line)
        return
    }
    if let m = SEMParityCompare.mismatch(actual: actual, reference: reference) {
        XCTFail(m.description, file: file, line: line)
    }
}

/// Assert a scalar against a reference scalar at its tolerance.
nonisolated func SEMAssertParity(_ actual: Double, _ reference: SEMParityReference, scalar name: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
    guard let s = reference.manifest.scalars[name] else {
        XCTFail("\(reference.manifest.caseName): no scalar \(name)", file: file, line: line)
        return
    }
    if let m = SEMParityCompare.mismatch(name: name, actual: [actual], expected: [s.value], rtol: s.rtol, atol: s.atol) {
        XCTFail(m.description, file: file, line: line)
    }
}
