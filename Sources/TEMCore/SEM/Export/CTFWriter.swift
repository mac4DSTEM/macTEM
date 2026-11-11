//
//  CTFWriter.swift
//  Role: write a `CrystalMap` as an Oxford Instruments Channel Text File (`.ctf`) that orix 0.15.0's
//        `orix/io/plugins/ctf.py` `file_reader` reads back to the written precision (figure F18). orix, kikuchipy and
//        rosettasciio write no .ctf, so the layout is AZtec's as orix reads it, stated once in
//        `tools/parity/sem/ctf_writer.py` (the reference this port matches byte for byte) and decided in docs/decisions.md:
//        the header (project, author, grid, cells, steps, the CS0 line, one line per phase: a;b;c, alpha;beta;gamma, name,
//        Laue group id 1-11 as orix's reader numbers them, space group or 0), then per point of the data extent, tab
//        separated: Phase (0 = not indexed, else 1...n in the phase list's order), X, Y, Bands, Error, Euler1-3 in degrees
//        (the rotations' Bunge angles times 180/π), MAD, BC, BS. Points not indexed or not in data are phase 0 with Euler 0;
//        Bands, Error, MAD, BC, BS come from the map's properties where it has them (names compared lowercased without
//        underscores: bands; error; mad, meanangulardeviation; bc, bandcontrast; bs, bandslope), integers rounded half to
//        even, else 0 and Error 3 ("no solution") where not indexed. An integer column's cell with no integer value (past the
//        last point of a scan stopped mid-row, where the map holds NaN, or a value beyond Int) takes that same fallback.
//        Coordinates restart at 0 on the data extent, as the .ang writer does. The phase's Laue group comes from its point
//        group name; a phase with none is Laue group −1.
//
//        Parity: `tools/parity/sem` bundles `m8/write-ctf-*`: the written bytes equal the reference writer's for the sdss
//        map, its ferrite points, a 10 × 10 window and the Ti head; orix reads each back to the written precision.
//

import FormatoCore
import Foundation

package nonisolated enum CTFWriter {
    package static let fileExtension = "ctf"

    /// orix's reader's Laue group ids (`_get_phases_from_header`), inverted.
    static let laueIDs = ["-1": 1, "2/m": 2, "mmm": 3, "4/m": 4, "4/mmm": 5, "-3": 6, "-3m": 7, "6/m": 8, "6/mmm": 9, "m-3": 10, "m-3m": 11]

    /// The file's text; `project` is the `Prj` line, `author` the `Author` line.
    package static func text(of map: CrystalMap, project: String = "macEM", author: String = "macEM") throws -> String {
        let grid = try CrystalMapExtent(map)
        let n = grid.count
        let phases = map.phases.entries.filter { $0.id != PhaseList.notIndexedID }

        var out = "Channel Text File\nPrj\t\(project)\nAuthor\t\(author)\nJobMode\tGrid\nXCells\t\(grid.columns)\nYCells\t\(grid.rows)\n"
        out += "XStep\t\(String(format: "%.4f", grid.dx))\nYStep\t\(String(format: "%.4f", grid.dy))\n"
        out += "AcqE1\t0.0000\nAcqE2\t0.0000\nAcqE3\t0.0000\n"
        out += "Euler angles refer to Sample Coordinate system (CS0)!\tMag\t0\tCoverage\t100\tDevice\t0\tKV\t0\tTiltAngle\t0\tTiltAxis\t0\n"
        out += "Phases\t\(phases.count)\n"
        for (i, entry) in phases.enumerated() {
            let phase = entry.phase
            let l = phase.lattice ?? CrystalMapExtent.defaultLattice
            let name = phase.name.isEmpty ? "phase\(i + 1)" : phase.name.replacingOccurrences(of: "\t", with: " ")
            let laue = PointGroup.laueName(phase.pointGroupName).flatMap { laueIDs[$0] } ?? 1
            out += String(format: "%.4f;%.4f;%.4f\t%.3f;%.3f;%.3f\t", l[0], l[1], l[2], l[3], l[4], l[5])
            out += "\(name)\t\(laue)\t\(phase.spaceGroup ?? 0)\n"
        }
        out += "Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS\n"

        let indexed = grid.indexed
        let angles = map.rotationsInData.map(RotationConversions.qu2eu)
        var euler = [[Double]](repeating: [], count: 3)
        for k in 0..<3 { euler[k] = map.mapData(angles.map { $0[k] * (180.0 / Double.pi) }, fill: 0) }

        let originalIDs = map.mapData(map.phaseIDs.map(Double.init), fill: .nan)
        var phaseColumn = [Int](repeating: 0, count: n)
        for (i, entry) in phases.enumerated() {
            for p in 0..<n where originalIDs[p] == Double(entry.id) { phaseColumn[p] = i + 1 }
        }

        func column(_ names: [String]) -> [Double]? {
            guard let name = CrystalMapExtent.property(in: map, named: names), let values = map.property(name) else { return nil }
            return map.mapData(values, fill: 0)
        }
        func integers(_ values: [Double]?, _ fallback: (Int) -> Int) -> [Int] {
            guard let values else { return (0..<n).map(fallback) }
            return values.enumerated().map { i, v in Int(exactly: v.rounded(.toNearestOrEven)) ?? fallback(i) }
        }
        let bands = integers(column(["bands"])) { _ in 0 }
        let error = integers(column(["error"])) { indexed[$0] ? 0 : 3 }
        let mad = column(["mad", "meanangulardeviation"]) ?? [Double](repeating: 0, count: n)
        let bc = integers(column(["bc", "bandcontrast"])) { _ in 0 }
        let bs = integers(column(["bs", "bandslope"])) { _ in 0 }

        out.reserveCapacity(out.utf8.count + n * 80)
        for i in 0..<n {
            let ok = indexed[i]
            out += "\(ok ? phaseColumn[i] : 0)\t\(String(format: "%.4f\t%.4f", grid.x[i], grid.y[i]))\t\(bands[i])\t\(error[i])\t"
            out += String(format: "%.4f\t%.4f\t%.4f\t%.4f", ok ? euler[0][i] : 0, ok ? euler[1][i] : 0, ok ? euler[2][i] : 0, mad[i])
            out += "\t\(bc[i])\t\(bs[i])\n"
        }
        return out
    }

    /// Writes the file through `FormatoFileWrite` (a scratch file first, then over `url`).
    package static func write(_ map: CrystalMap, to url: URL, project: String? = nil, author: String = "macEM") throws {
        let name = project ?? url.deletingPathExtension().lastPathComponent
        try FormatoFileWrite.write(Data(try text(of: map, project: name, author: author).utf8), to: url)
    }
}
