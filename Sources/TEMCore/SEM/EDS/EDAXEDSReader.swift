//
//  EDAXEDSReader.swift
//  Role: EDAX Genesis and TEAM files read as RosettaSciIO 0.15.0 reads them (`rsciio/edax/_api.py`, GPL-3.0-or-later):
//        `.spd` — the spectrum map: a 1068-byte header ("MAPSPECTRA_DATA", nSpectra, nPoints = columns, nLines = rows, nChannels,
//        countBytes 1, 2 or 4, dataOffset, the electron image's file name) and the counts, pixel by pixel; `.lsd` — the line scan in
//        the same layout, its first nSpectra spectra, calibrated along x by the `.csv` beside it (the "Distance (nm)" column);
//        `.spc` — one spectrum (version-dependent header: dataStart, numPts, evPerChan, startEnergy, liveTime, tilt, detReso,
//        azimuth, elevation, kV, the identified elements). The `.spc` of the same name gives an `.spd`/`.lsd` its energy axis and
//        detector metadata; the `.ipr` named after the electron image (`fName` with `.ipr`) gives the map its µm per pixel. Without
//        them rsciio's fallbacks hold (scale 1, offset 1, no units), as here. An `.ipr` or `.csv` that is there but cannot be read
//        (the sandboxed app is given the picked file only) is left out the same way, with a note in the file's `notes`; an
//        unreadable `.spc` still fails the read in words, since the map has no energy axis without it. Float32 header values
//        are carried as their exact doubles.
//

import Foundation

package nonisolated enum EDAXEDSReader {
    package static let readableExtensions = ["spd", "lsd", "spc"]

    package static func read(url: URL) throws -> SEMEDSFile {
        switch url.pathExtension.lowercased() {
        case "spd", "lsd": return try readMap(url: url)
        case "spc": return try readSPC(url: url)
        default: throw SEMEDSReadError("\(url.lastPathComponent) is not an EDAX .spd, .lsd or .spc file.")
        }
    }

    static func bytes(_ url: URL, limit: Int? = nil) throws -> SEMEDSBytes {
        do {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let read: Data?
            if let limit { read = try h.read(upToCount: limit) } else { read = try h.readToEnd() }
            let d = read ?? Data()
            return SEMEDSBytes([UInt8](d), name: url.lastPathComponent)
        } catch {
            throw SEMEDSReadError("\(url.lastPathComponent) could not be read: \(ErrorDetail.text(error))")
        }
    }

    /// The `.spc` header fields rsciio reads (the short dtype list; the same offsets for versions 0.61 and 0.70).
    struct SPCHeader {
        var dataStart: Int
        var numPts: Int
        var evPerChan: Int32
        var startEnergy: Float
        var liveTime: Float
        var tilt: Float
        var detReso: Float
        var azimuth: Float
        var elevation: Float
        var kV: Float
        var elements: [Int]

        init(_ b: SEMEDSBytes) throws {
            try b.need(0, 20740)
            dataStart = Int(try b.i32(28))
            numPts = Int(try b.i16(32))
            evPerChan = try b.i32(384)
            startEnergy = try b.f32(448)
            liveTime = try b.f32(456)
            tilt = try b.f32(460)
            detReso = try b.f32(472)
            azimuth = try b.f32(508)
            elevation = try b.f32(512)
            kV = try b.f32(532)
            let n = Int(try b.i16(638))
            elements = n > 0 ? try (0..<min(n, 48)).map { Int(try b.u16(640 + 2 * $0)) } : []
        }

        /// rsciio `_add_spc_metadata`.
        func apply(to md: inout SEMEDSMetadata) {
            md.mode = "SEM"
            md.azimuthAngle = Double(azimuth)
            md.elevationAngle = Double(elevation)
            md.energyResolutionMnKa = Double(detReso)
            md.liveTime = Double(liveTime)
            md.beamEnergy = Double(kV)
            md.tiltAlpha = Double(tilt)
            if !elements.isEmpty { md.elements = elements.compactMap { SEMEDSElements.symbol($0) }.sorted() }
        }
    }

    static func readSPC(url: URL) throws -> SEMEDSFile {
        let b = try bytes(url)
        let h = try SPCHeader(b)
        guard h.numPts >= 0 else { throw SEMEDSReadError("\(url.lastPathComponent) states \(h.numPts) channels.") }
        // numpy's fromfile stops at the end of the file.
        let available = max(0, (b.bytes.count - h.dataStart) / 4)
        let n = min(h.numPts, available)
        let counts = try (0..<n).map { Int64(try b.u32(h.dataStart + 4 * $0)) }
        var md = SEMEDSMetadata()
        md.originalFilename = url.lastPathComponent
        md.title = "EDS Spectrum"
        md.signalType = "EDS_SEM"
        h.apply(to: &md)
        let axis = SEMEDSAxis(name: "Energy", size: n, scale: Double(h.evPerChan) / 1000.0, offset: Double(h.startEnergy), units: "keV")
        return SEMEDSFile(url: url, signals: [.spectrum(SEMEDSSpectrum(axis: axis, dtype: "uint32", counts: counts, metadata: md))])
    }

    /// `os.path.splitext(os.path.basename(name))[0]` as rsciio takes it: the text after the last "/" up to its last ".", whatever
    /// follows (`fName` can hold a NUL and padding after the extension, which a path API would not call an extension).
    static func pythonStem(_ name: String) -> String {
        let base = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        guard let dot = base.lastIndex(of: "."), base[base.startIndex..<dot].contains(where: { $0 != "." }) else { return base }
        return String(base[base.startIndex..<dot])
    }

    static func companion(_ url: URL, name: String) -> URL? {
        let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// `companion` when it can be opened. One that is there but cannot be (macOS has not given the sandboxed app access to it,
    /// a disk error) is nil, as a missing one is, and `notes` says what the file at `url` opens without: rsciio's fallback.
    static func readable(_ companion: URL?, beside url: URL, notes: inout [String], lacking: String) -> URL? {
        guard let companion else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: companion) else {
            notes.append("\(companion.lastPathComponent) beside \(url.lastPathComponent) could not be read: \(lacking).")
            return nil
        }
        try? handle.close()
        return companion
    }

    static func readMap(url: URL) throws -> SEMEDSFile {
        let name = url.lastPathComponent
        let lineScan = url.pathExtension.lowercased() == "lsd"
        let head = try bytes(url, limit: 1068)
        try head.need(0, 1068)
        let nSpectra = Int(try head.i32(20))
        let nx = Int(try head.i32(24))
        let ny = Int(try head.u32(28))
        let nz = Int(try head.u32(32))
        let countBytes = Int(try head.u32(36))
        let dataOffset = Int(try head.u32(40))
        let fName = SEMEDSText.decode(try head.slice(48, 120))
        guard [1, 2, 4].contains(countBytes) else { throw SEMEDSReadError("\(name) stores \(countBytes)-byte counts; EDAX writes 1, 2 or 4.") }
        guard nx > 0, ny > 0, nz > 0 else { throw SEMEDSReadError("\(name) states a map of \(nx) x \(ny) pixels and \(nz) channels.") }

        // The `.spc` of the same name: the energy axis and the detector.
        var md = SEMEDSMetadata()
        md.originalFilename = name
        md.signalType = "EDS_SEM"
        let spcURL = url.deletingPathExtension().appendingPathExtension("spc")
        var spc: SPCHeader?
        if FileManager.default.fileExists(atPath: spcURL.path) {
            spc = try SPCHeader(try bytes(spcURL, limit: 20740))
            spc?.apply(to: &md)
        }
        let energy = SEMEDSAxis(name: "Energy", size: nz, scale: spc.map { Double($0.evPerChan) / 1000.0 } ?? 1,
                                offset: spc.map { Double($0.startEnergy) } ?? 1, units: spc == nil ? nil : "keV")

        // The counts: numpy reads nx · ny · nz values (fewer if the file is short).
        let (rows, cols): (Int, Int)
        var axes: [SEMEDSAxis]
        let shape: [Int]
        var notes: [String] = []
        if lineScan {
            // nx · ny overflows only far above any nSpectra (an Int32), which then is the smaller.
            let grid = nx.multipliedReportingOverflow(by: ny)
            let kept = grid.overflow ? nSpectra : min(nSpectra, grid.partialValue)
            rows = 1; cols = max(kept, 0)
            md.title = "EDS Line Scan"
            var scale = 1.0, offset = 0.0, units: String?
            let csvName = url.deletingPathExtension().lastPathComponent + ".csv"
            if let csv = readable(companion(url, name: csvName), beside: url, notes: &notes, lacking: "the line scan has no distances") {
                let distances = try lineScanDistances(csv)
                if distances.count >= 2 { offset = distances[0]; scale = distances[1] - distances[0]; units = "nm" }
                else if let first = distances.first { offset = first; units = "nm" }
                else { units = "µm" }
            }
            axes = [SEMEDSAxis(name: "x", size: cols, scale: scale, offset: offset, units: units), energy]
            shape = [cols, nz]
        } else {
            rows = ny; cols = nx
            md.title = "EDS Spectrum Image"
            let iprName = pythonStem(fName) + ".ipr"
            var mppX: Float?, mppY: Float?
            if let ipr = readable(companion(url, name: iprName), beside: url, notes: &notes, lacking: "the map has no pixel size") {
                let b = try bytes(ipr, limit: 264)
                mppX = try b.f32(64); mppY = try b.f32(68)
            }
            let units: String? = mppX == nil ? nil : "µm"
            axes = [SEMEDSAxis(name: "y", size: ny, scale: mppY.map(Double.init) ?? 1, offset: 0, units: units),
                    SEMEDSAxis(name: "x", size: nx, scale: mppX.map(Double.init) ?? 1, offset: 0, units: units), energy]
            shape = [ny, nx, nz]
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw SEMEDSReadError("\(name) could not be read: \(ErrorDetail.text(error))") }
        defer { try? handle.close() }
        let pixelBytes = nz * countBytes
        // The counts the header states must fit in the file after dataOffset before anything is allocated for them; a file
        // that holds fewer gets the sentence the read below would give it.
        let fileLength = Int((try? handle.seekToEnd()) ?? 0)
        do {
            _ = try SEMEDSFile.checkedCount(dims: [rows, cols, nz], bytesPerItem: countBytes, fileLength: max(0, fileLength - dataOffset),
                                            name: name)
        } catch {
            throw SEMEDSReadError("\(name) holds fewer spectra than its header states (\(nx) x \(ny) of \(nz) channels).")
        }
        guard (try? handle.seek(toOffset: UInt64(dataOffset))) != nil else { throw SEMEDSReadError("\(name) ends before its data.") }
        var builder = try CSRSpectrumImageBuilder(ny: rows, nx: cols, channels: nz)
        var spectrum = [UInt32](repeating: 0, count: nz)
        let pixels = rows * cols
        let blockPixels = max(1, (8 << 20) / pixelBytes)
        var p = 0
        while p < pixels {
            let n = min(blockPixels, pixels - p)
            let data = (try? handle.read(upToCount: n * pixelBytes)) ?? Data()
            guard data.count == n * pixelBytes else {
                throw SEMEDSReadError("\(name) holds fewer spectra than its header states (\(nx) x \(ny) of \(nz) channels).")
            }
            data.withUnsafeBytes { raw in
                for k in 0..<n {
                    let base = k * pixelBytes
                    for c in 0..<nz {
                        let o = base + c * countBytes
                        switch countBytes {
                        case 1: spectrum[c] = UInt32(raw[o])
                        case 2: spectrum[c] = UInt32(raw[o]) | UInt32(raw[o + 1]) << 8
                        default: spectrum[c] = UInt32(raw[o]) | UInt32(raw[o + 1]) << 8 | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24
                        }
                    }
                    spectrum.withUnsafeBufferPointer { builder.append(spectrum: $0) }
                }
            }
            p += n
        }
        let cube = builder.finish()
        return SEMEDSFile(url: url, signals: [.spectrumImage(SEMEDSSpectrumImage(shape: shape, axes: axes, dtype: "uint\(countBytes * 8)",
                                                                                cube: cube, metadata: md))], notes: notes)
    }

    /// The "Distance (nm)" column of an EDAX line-scan `.csv`: 14 header lines, then a table (rsciio reads it with `csv.DictReader`).
    static func lineScanDistances(_ url: URL) throws -> [Double] {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            throw SEMEDSReadError("\(url.lastPathComponent) could not be read as text.")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.count > 15 else { return [] }
        let header = lines[14].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let column = header.firstIndex(of: "Distance (nm)") else {
            throw SEMEDSReadError("\(url.lastPathComponent) has no \"Distance (nm)\" column.")
        }
        var out: [Double] = []
        for line in lines.dropFirst(15) where !line.isEmpty {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard column < cells.count, let v = Double(cells[column]) else {
                throw SEMEDSReadError("\(url.lastPathComponent) has a row without a distance.")
            }
            out.append(v)
        }
        return out
    }
}

/// Element symbols by atomic number (1 to 118), for the element lists files store as numbers.
package nonisolated enum SEMEDSElements {
    static let symbols: [String] = ["H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
        "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr", "Rb", "Sr", "Y", "Zr",
        "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn", "Sb", "Te", "I", "Xe", "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm",
        "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb", "Lu", "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb",
        "Bi", "Po", "At", "Rn", "Fr", "Ra", "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr",
        "Rf", "Db", "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og"]

    package static func symbol(_ z: Int) -> String? { z >= 1 && z <= symbols.count ? symbols[z - 1] : nil }
}
