// The periodic table the EDX room picks from, and what SpectroKit's line table can serve (mac4DSTEM's PeriodicLayout and
// ElementSelection.unavailableReason, cut to what macTEM's room reads).
import Foundation
import SpectroEDX

package enum EDXElements {
    package static let symbols: [String] = ("H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr "
        + "Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu "
        + "Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr "
        + "Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og").split(separator: " ").map(String.init)

    package static func symbol(z: Int) -> String { symbols[z - 1] }
    package static func z(of symbol: String) -> Int? { symbols.firstIndex(of: symbol).map { $0 + 1 } }

    /// Why an element cannot be picked: no usable line at an EDX detector window below Z = 5, and none for an element the line
    /// table carries without lines (a pick there could never fit or map anything). nil when it can be picked.
    package static func unavailableReason(symbol: String) -> String? {
        guard let z = z(of: symbol) else { return "Not an element" }
        if z <= 4 { return "No usable X-ray line at this detector window" }
        return XRayLines.lines(of: symbol).isEmpty ? "No X-ray line in the table" : nil
    }

    /// One line the right-click menu offers: its id, its words ("Kα 1.487 keV") and whether the pick has it checked.
    package struct LineChoice: Equatable, Sendable {
        package let id: String
        package let title: String
        package let isChecked: Bool
    }

    /// A family of one element with its lines; `isSelected` is the family the maps sum.
    package struct LineFamilyChoice: Equatable, Sendable {
        package let family: XRayFamily
        package let isSelected: Bool
        package let lines: [LineChoice]
    }

    /// A line weaker than this against its family's alpha is not offered: its window would hold noise.
    package static let minimumLineWeight = 0.01

    /// The menu of an element: per family the table has, its lines (alpha first) with their energies, the pick's family and checked lines marked. `energy` words an energy
    /// ("1.487"); the default is three decimals.
    package static func lineFamilies(symbol: String, pick: EDXPick?, energy: (Double) -> String = { String(format: "%.3f", $0) }) -> [LineFamilyChoice] {
        let all = XRayLines.lines(of: symbol)
        let families: [XRayFamily] = [.K, .L, .M]
        // The family the maps sum without a choice: the table's first with lines (K for light elements, L then M for heavy ones).
        let defaultFamily = families.first { f in all.contains { $0.family == f && $0.weight >= minimumLineWeight } }
        return families.compactMap { f in
            let lines = all.filter { $0.family == f && $0.weight >= minimumLineWeight }
            guard !lines.isEmpty else { return nil }
            return LineFamilyChoice(family: f, isSelected: (pick?.family ?? defaultFamily) == f,
                                    lines: lines.map { LineChoice(id: $0.id, title: "\(ElementWindows.shortLabel(ofLineID: $0.id)) \(energy($0.energy)) keV", isChecked: pick?.lines.contains($0.id) ?? false) })
        }
    }
}
