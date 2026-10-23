// Pinned regions of the EDX room: a region kept under a name, and the CSV that lists them. The numbers in a row are the kit's: the
// region's summed spectrum, `ElementWindows.netCounts` on it, and (when the maps' factors are complete) `EDXQuantification.quantify`
// on those net counts; this file chooses the inputs and writes the text. The CSV also reads back (`parse`), so a pin set survives a
// round trip through a file.
import Foundation
import SpectroCore
import SpectroEDX

/// A colour a person picked for a region or line, as sRGB numbers 0...1. nil on the pin means "the palette's colour for its number" (the app's).
package struct EDXPinColor: Equatable, Sendable {
    package var red: Double, green: Double, blue: Double
    package init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
}

package struct EDXPin: Equatable, Identifiable, Sendable {
    package var id: UUID
    package var name: String
    package var region: EDXRegion
    /// The running count of pins made in this image (1 for the first); the palette colour and the default name follow it. 0 for a pin read from a CSV.
    package var number: Int
    package var color: EDXPinColor?
    /// Hidden pins keep their place in the list and the table but are not drawn on the maps or the spectrum.
    package var isVisible: Bool
    package init(id: UUID = UUID(), name: String, region: EDXRegion, number: Int = 0, color: EDXPinColor? = nil, isVisible: Bool = true) {
        self.id = id; self.name = name; self.region = region; self.number = number; self.color = color; self.isVisible = isVisible
    }
}

package enum EDXPins {

    /// One pin's row: its pixels, the counts in its spectrum, the net counts of the picked elements' windows and, when the factors
    /// allow it, their composition.
    package struct Row: Equatable, Sendable {
        package var pin: EDXPin
        package var pixels: Int
        package var counts: UInt64
        package var elements: [String]
        package var net: [Double?]
        package var weightPercent: [Double]?
        package var atomicPercent: [Double]?
    }

    /// The rows for `pins`: spectra summed (cached by region), windows of the quantified `symbols` read in each, and the composition
    /// from `setup` where it applies. `setup.elements` must be `symbols` in order, or nil.
    package static func rows(pins: [EDXPin], source: any SpectrumImageSource, symbols: [String], setup: EDXQuantificationSetup?,
                             cache: EDXComputeCache) -> [Row] {
        let windows = ElementWindows.build(picks: symbols.map { ElementWindows.Pick(symbol: $0) }, axis: source.energyAxis,
                                           beamEnergyKeV: source.metadata.beamEnergyKeV)
        return pins.map { pin in
            let spectrum = EDXCompute.spectrum(source: source, region: pin.region, cache: cache)
            let counts = ElementWindows.netCounts(spectrum: spectrum, windows: windows)
            let net: [Double?] = symbols.map { s in
                let parts = windows.indices.filter { windows[$0].element == s }.compactMap { counts[$0]?.net }
                return parts.isEmpty ? nil : parts.reduce(0, +)
            }
            var wt: [Double]?, at: [Double]?
            if let setup, net.allSatisfy({ $0 != nil }), let q = try? EDXQuantification.quantify(intensities: net.map { $0! }, setup: setup) {
                wt = q.weightPercent; at = q.atomicPercent
            }
            return Row(pin: pin, pixels: pin.region.pixelCount(nx: source.nx, ny: source.ny), counts: spectrum.reduce(0, &+),
                       elements: symbols, net: net, weightPercent: wt, atomicPercent: at)
        }
    }

    // MARK: CSV

    package static func geometry(_ r: EDXRegion) -> String {
        switch r {
        case .wholeMap: ""
        case .rectangle(let p), .ellipse(let p): "\(p.x0) \(p.y0) \(p.x1) \(p.y1)"
        case .polygon(let v): v.map { "\(g($0.x)) \(g($0.y))" }.joined(separator: ";")
        }
    }

    private static func g(_ v: Double) -> String { String(format: "%.10g", v) }

    package static func csv(rows: [Row], fileName: String, title: String = "macTEM EDX pins") -> String {
        let elements = rows.first?.elements ?? []
        var out = ["# \(title), file: \(fileName)",
                   "# net_<El>: net counts of the element's line window in the pin's summed spectrum; wt_ and at_: Cliff-Lorimer / zeta / cross-section composition of those nets with the maps' factors, validation: \(EDXQuantification.validation); empty when the factors are not complete",
                   (["name", "shape", "geometry", "pixels", "counts"] + elements.map { "net_\($0)" } + elements.map { "wt_\($0)" } + elements.map { "at_\($0)" })
                    .joined(separator: ",")]
        for r in rows {
            var cells = [quote(r.pin.name), r.pin.region.shapeName, quote(geometry(r.pin.region)), "\(r.pixels)", "\(r.counts)"]
            cells += r.net.map { $0.map { String(format: "%.6g", $0) } ?? "" }
            cells += elements.indices.map { i in r.weightPercent.map { String(format: "%.6g", $0[i]) } ?? "" }
            cells += elements.indices.map { i in r.atomicPercent.map { String(format: "%.6g", $0[i]) } ?? "" }
            out.append(cells.joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func quote(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// The pins a `csv` file lists: name, shape and geometry (the numbers are recomputed from the image, not read back). nil for a file
    /// that is not this CSV; a row whose shape or geometry does not parse is skipped.
    package static func parse(_ text: String) -> [EDXPin]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.hasPrefix("#") }
        guard let header = lines.first, header.hasPrefix("name,shape,geometry,pixels,counts") else { return nil }
        return lines.dropFirst().compactMap { line in
            let cells = split(line)
            guard cells.count >= 3, let region = region(shape: cells[1], geometry: cells[2]) else { return nil }
            return EDXPin(name: cells[0], region: region)
        }
    }

    private static func region(shape: String, geometry: String) -> EDXRegion? {
        switch shape {
        case "whole": return .wholeMap
        case "rectangle", "ellipse":
            let n = geometry.split(separator: " ").compactMap { Int($0) }
            guard n.count == 4 else { return nil }
            let r = PixelRect(x0: n[0], y0: n[1], x1: n[2], y1: n[3])
            return shape == "rectangle" ? .rectangle(r) : .ellipse(r)
        case "polygon":
            let pts = geometry.split(separator: ";").compactMap { pair -> PixelPoint? in
                let v = pair.split(separator: " ").compactMap { Double($0) }
                return v.count == 2 ? PixelPoint(x: v[0], y: v[1]) : nil
            }
            return pts.isEmpty ? nil : .polygon(pts)
        default: return nil
        }
    }

    /// One CSV line into cells, honouring double quotes.
    private static func split(_ line: String) -> [String] {
        var cells: [String] = [], cur = "", quoted = false
        var it = line.makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { cur.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true } else if c == "," { cells.append(cur); cur = "" } else { cur.append(c) }
        }
        cells.append(cur)
        return cells
    }
}
