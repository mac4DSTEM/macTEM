//
//  TypedWholeNumber.swift
//  Role: the whole number a typed entry stands for, for every inspector field that holds a count or a size in pixels: the Patterns
//        room's NLPAR search radius and equalisation kernel, the EELS room's Richardson-Lucy iterations, and the Indexing room's Keep
//        (Dictionary) and Bands, ρ bins, θ bins and Early exit (Hough). The field hands over a Double, and a typed 1e20 or a non-finite value would trap
//        in the conversion to `Int`; here it is rounded and held within ±10⁹, so the setting's own refusal names it. One rule for all
//        eight fields (#425: the Indexing room kept a private copy).
//

nonisolated enum TypedWholeNumber {
    /// `v` rounded and held within ±10⁹; 0 for a non-finite value.
    static func value(_ v: Double) -> Int {
        v.isFinite ? Int(min(max(v.rounded(), -1e9), 1e9)) : 0
    }
}
