//
//  MarkEdits.swift
//  Role: the Image room's mark edits that the record can refuse (V1-2 slice B's UI, with ADR 023 a): a move or a width
//        whose longer number would take the saved text past the 60,000-byte budget is declined by `ImageMeasurements` and the
//        mark is put back — it returns nothing, so this reads the mark before and after to tell a refusal from a no-op, and
//        the caller says so (`MarkRefusalText`). An add returns its refusal itself and needs no help here.
//
//        Presentation-adjacent only: the decision is the owner's (TEMSession); nothing is recorded here.
//

import Foundation
import TEMCore
import TEMSession

@MainActor
enum MarkEdits {
    /// Moves point `index` of mark `id` to `point`. True when the record refused (the mark is where it was and `point`,
    /// held inside the image as the owner holds it, is somewhere else).
    @discardableResult
    static func move(_ id: ImageMark.ID, point index: Int, to point: ImagePoint, on image: CalibratedImage,
                     in measurements: ImageMeasurements) -> Bool {
        guard let before = measurements.mark(id)?.points[safe: index], point.x.isFinite, point.y.isFinite else { return false }
        measurements.move(id, point: index, to: point, on: image)
        let wanted = ImagePoint(x: min(max(point.x, -0.5), Double(image.width) - 0.5),
                                y: min(max(point.y, -0.5), Double(image.height) - 0.5))
        return measurements.mark(id)?.points[safe: index] == before && wanted != before
    }

    /// Sets a profile's width. True when the record refused.
    @discardableResult
    static func setWidth(_ id: ImageMark.ID, _ width: Int, on image: CalibratedImage, in measurements: ImageMeasurements) -> Bool {
        guard let before = measurements.mark(id), before.kind == .profile else { return false }
        measurements.setWidth(id, width, on: image)
        let wanted = min(max(width, 1), ImageMeasurements.maximumWidth)
        return measurements.mark(id)?.width == before.width && wanted != before.width
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
