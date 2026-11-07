//
//  SEMImageMetadata+Image.swift
//  Role: what the SEM record does to the image the room shows: supplies the axes RosettaSciIO's vendor branch gives a file
//        the app's TIFF reader left uncalibrated (a Zeiss or Tescan file: FormatoKit's `TIFFAppImage` reads the Thermo INI
//        calibration itself), and cuts the vendor's databar off the bottom so the room shows the scan alone. Pure functions
//        of a `CalibratedImage`; the app decides when (the Calibration section's switch, on by default).
//

import Foundation
import ImagoCore

nonisolated extension SEMImageMetadata {
    /// `image` with the record's pixel size on both axes (metres) where the file's own reader gave it none; otherwise `image`
    /// as it is: a calibration FormatoKit read is never replaced.
    package func calibrated(_ image: CalibratedImage) -> CalibratedImage {
        guard image.x?.isCalibrated != true, image.y?.isCalibrated != true,
              let sx = pixelSizeX, let sy = pixelSizeY, sx > 0, sy > 0, sx.isFinite, sy.isFinite else { return image }
        return CalibratedImage(width: image.width, height: image.height, pixels: image.pixels,
                               x: AxisCalibration(scale: sx, unit: "m"), y: AxisCalibration(scale: sy, unit: "m"),
                               fileName: image.fileName, source: image.source, voltage: image.voltage, notes: image.notes)
    }

    /// `image` without its last `databarRows` rows; `image` itself when the record names no databar or the rows do not fit
    /// the image handed in (a frame of another size).
    package func cropped(_ image: CalibratedImage) -> CalibratedImage {
        guard let rows = databarRows, rows > 0, image.height == imageHeight, image.height - rows > 0 else { return image }
        let keep = image.height - rows
        return CalibratedImage(width: image.width, height: keep, pixels: Array(image.pixels[0..<(image.width * keep)]),
                               x: image.x, y: image.y, fileName: image.fileName, source: image.source, voltage: image.voltage,
                               notes: image.notes)
    }

    /// Both, in the order the app applies them: the axes, then the crop when `cropDatabar`.
    package func applied(to image: CalibratedImage, cropDatabar: Bool) -> CalibratedImage {
        let calibrated = calibrated(image)
        return cropDatabar ? cropped(calibrated) : calibrated
    }
}
