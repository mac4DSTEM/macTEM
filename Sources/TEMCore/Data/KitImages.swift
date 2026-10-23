//
//  KitImages.swift
//  Role: the one place a FormatoKit image becomes macTEM's `CalibratedImage` and a kit axis its `AxisCalibration`: the TIFF and MRC
//        readings (`TIFFAppImage.Image`, `MRCAppImage.Image`) and the Velox axes (`VeloxImageSelection.Axis`). Each carries the
//        same fields (width, height, Float32 pixels, origin/scale/units per axis, file name, source, notes); nothing is
//        converted, rounded or guessed here. A Velox image has no kit image type, so `VeloxImageReader` builds its
//        `CalibratedImage` from the kit's axes through `AxisCalibration(_:)` here.
//

import FormatoEMD
import ImagoCore
import FormatoMRC
import FormatoTIFF

extension AxisCalibration {
    package init(_ axis: TIFFAppImage.Axis) { self.init(scale: axis.scale, unit: axis.units, origin: axis.origin) }
    package init(_ axis: MRCAppImage.Axis) { self.init(scale: axis.scale, unit: axis.units, origin: axis.origin) }
    package init(_ axis: VeloxImageSelection.Axis) { self.init(scale: axis.scale, unit: axis.units, origin: axis.origin) }
}

extension CalibratedImage {
    /// A TIFF reading (voltage: a TIFF image carries none).
    package init(_ image: TIFFAppImage.Image) {
        self.init(width: image.width, height: image.height, pixels: image.pixels,
                  x: image.x.map(AxisCalibration.init), y: image.y.map(AxisCalibration.init),
                  fileName: image.fileName, source: image.source, voltage: nil, notes: image.notes)
    }

    /// An MRC reading (voltage: an MRC image carries none).
    package init(_ image: MRCAppImage.Image) {
        self.init(width: image.width, height: image.height, pixels: image.pixels,
                  x: image.x.map(AxisCalibration.init), y: image.y.map(AxisCalibration.init),
                  fileName: image.fileName, source: image.source, voltage: nil, notes: image.notes)
    }
}
