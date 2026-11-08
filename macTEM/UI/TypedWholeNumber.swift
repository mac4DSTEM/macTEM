//
//  TypedWholeNumber.swift
//  Role: the whole number a typed entry stands for, for the inspector fields that hold a count or a size in pixels (the NLPAR search
//        radius, the equalisation kernel, the Richardson-Lucy iterations). The field hands over a Double, and a typed 1e20 or a non-finite
//        value would trap in the conversion to `Int`; here it is rounded and held within ±10⁹, so the setting's own refusal names it.
//        The same rule as the Indexing room's whole-number fields (`IndexingRoomInspector`).
//

nonisolated enum TypedWholeNumber {
    /// `v` rounded and held within ±10⁹; 0 for a non-finite value.
    static func value(_ v: Double) -> Int {
        v.isFinite ? Int(min(max(v.rounded(), -1e9), 1e9)) : 0
    }
}
