//
//  CheckedConversion.swift
//  Role: the conversions from a floating-point value that trap on NaN, infinity or a value out of range (`UInt8(_:)`,
//        `Int(_:)`), made total. A NaN that reaches a colour is drawn as 0, and an index that is not a number is nil, so the
//        caller says "not indexed" or refuses in words instead of crashing (macEM 2.1.0 bundle B, #605 #608).
//

package nonisolated enum CheckedConversion {
    /// A fraction as a byte, rounded to the nearest: below 0 is 0, above 1 is 255, NaN is 0.
    @inline(__always)
    package static func unitByte(_ value: Double) -> UInt8 {
        value.isNaN ? 0 : UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    /// `unitByte` for a Float.
    @inline(__always)
    package static func unitByte(_ value: Float) -> UInt8 { unitByte(Double(value)) }

    /// `Int(value)`, truncation toward zero, when `value` is finite and the result fits an Int; nil otherwise.
    @inline(__always)
    package static func int(_ value: Double) -> Int? {
        value.isFinite ? Int(exactly: value.rounded(.towardZero)) : nil
    }
}
