//
//  Signposts.swift
//  Role: the app's own timings. An `os_signpost` interval around each heavy action's compute (open, FFT spectrum, spot, find spots,
//        EDX refresh, EELS map, particles, stack frame) in one subsystem, so a UI test reads them with `XCTOSSignpostMetric` and Instruments
//        shows them. No numerics, no state; a signpost costs nothing measurable when nothing is listening.
//

import os

package enum Signposts {
    package static let subsystem = "com.mac4dstem.macTEM"
    package static let category = "performance"
    private static let log = OSLog(subsystem: subsystem, category: category)

    package struct Interval {
        fileprivate let id: OSSignpostID
        fileprivate let name: StaticString
    }

    package static func begin(_ name: StaticString) -> Interval {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Interval(id: id, name: name)
    }

    package static func end(_ interval: Interval) {
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
    }
}
