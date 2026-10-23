// A TIFF series read on demand: a multi-page TIFF (or an ImageJ stack) opens as one frame at a time. FormatoKit's `TIFFSignals` lists the
// series; its lazy array reads the rows of ONE page with `pread`, so showing frame N touches that page and no other (a memory-peak test
// pins it). The file's sandbox scope is held for the source's life (`ScopeHold`), because frames are read long after the open that
// granted it. The kit does the reading and the calibration; this file is the seam to `CalibratedImage`.
import Foundation
import Synchronization
import FormatoCore
import FormatoTIFF
import ImagoCore

/// A security scope held until it is released (or the holder goes): `start` once at the open, `stop` once at the release. Injected so a
/// test can count both.
package final class ScopeHold: Sendable {
    package let url: URL
    private let stopAccess: @Sendable (URL) -> Void
    private let state: Mutex<Bool>   // true while held

    package init(url: URL, start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
                 stop: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stopAccess = stop
        self.state = Mutex(start(url))
    }

    /// Whether the scope is held now.
    package var isHeld: Bool { state.withLock { $0 } }

    /// Stops the access once; a second call does nothing.
    package func release() {
        let wasHeld = state.withLock { held -> Bool in let was = held; held = false; return was }
        if wasHeld { stopAccess(url) }
    }

    deinit { release() }
}

package nonisolated final class ImageStackSource: Sendable {
    package let path: String
    package let fileName: String
    package let frameCount: Int
    package let width: Int
    package let height: Int
    package let x: AxisCalibration?
    package let y: AxisCalibration?
    private let signal: FormatoLazySignal
    private let hold: ScopeHold?
    private let reads = Atomic<Int>(0)

    private init(path: String, signal: FormatoLazySignal, frameCount: Int, width: Int, height: Int, x: AxisCalibration?, y: AxisCalibration?, hold: ScopeHold?) {
        self.path = path; self.fileName = formatoDisplayFileName(path); self.signal = signal
        self.frameCount = frameCount; self.width = width; self.height = height; self.x = x; self.y = y; self.hold = hold
    }

    package var url: URL { URL(fileURLWithPath: path) }
    /// How many frames have been read since the open: a test asserts one frame shown is one frame read.
    package var framesRead: Int { reads.load(ordering: .relaxed) }
    package var holdsScope: Bool { hold?.isHeld ?? false }

    /// Lets go of the file's sandbox scope (the item closed). Frames read after this may be refused by the sandbox.
    package func release() { hold?.release() }

    /// The stack in the file at `path`: the first series when it is grey frames of one size (axes of three dimensions, more than one
    /// frame); nil for a single image, a colour series or anything else the single-image reader should answer for. Throws the kit's
    /// error for a file that cannot be read as a TIFF.
    package static func open(path: String, hold: ScopeHold? = nil) throws -> ImageStackSource? {
        let signals = try TIFFSignals(path: path)
        guard let series = signals.series.first, series.shape.count == 3, series.shape[0] > 1, series.dataType.components == 1 else { return nil }
        let signal = try signals.signal(series: 0)
        guard signal.axes.count == 3 else { return nil }
        func calibration(_ a: FormatoAxis) -> AxisCalibration? {
            guard a.scale.isFinite, a.scale > 0, !a.units.isEmpty else { return nil }
            return AxisCalibration(offset: a.offset, scale: a.scale, unit: a.units)
        }
        return ImageStackSource(path: path, signal: signal, frameCount: series.shape[0], width: series.shape[2], height: series.shape[1],
                                x: calibration(signal.axes[2]), y: calibration(signal.axes[1]), hold: hold)
    }

    /// Frame `index` as macTEM's image: that page's rows only, converted to Float32.
    package func frame(_ index: Int) throws -> CalibratedImage {
        guard index >= 0, index < frameCount else { throw FormatoReadError.unsupported("The stack has \(frameCount) frames; there is no frame \(index + 1).") }
        let slab = try signal.array.read(start: [index, 0, 0], count: [1, height, width])
        reads.add(1, ordering: .relaxed)
        let pixels = slab.doubles().map { Float($0) }
        return CalibratedImage(width: width, height: height, pixels: pixels, x: x, y: y, fileName: fileName,
                               source: "frame \(index + 1) of \(frameCount)", voltage: nil, notes: ["frame \(index + 1) of \(frameCount)"])
    }
}
