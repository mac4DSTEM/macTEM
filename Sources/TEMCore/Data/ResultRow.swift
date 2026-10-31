//
//  ResultRow.swift
//  Role: one finished measurement of one file, as the Results room lists it and `ResultsCSV` writes it. A value:
//        derived by `ResultsLedger` (TEMSession) from the owners of the marks and the FFT spots, never stored, and holding
//        every number as the owner's own Double.
//
//  THE ROOM AUTHORS NO CLAIM OF TRUST (R-P2). What a measurement is checked against is `Product.validation`, and each case
//  returns its PRODUCER's own constant (`ImageMeasurement.validation`, `FFTExport.spotsValidation`; a profile row's numbers are closed
//  forms, so it carries `ImageMeasurement.validation`, then `ProfileCSV.validation` for the samples the Image room's CSV writes);
//  the switch is exhaustive, so a new product without a constant does not compile. `Product.badge` is the short label of the
//  same claim. "Validated" is never written: a product that is not checked says so in its own constant.
//
//  THE NUMBERS are the owner's Doubles in the file's own unit (a Velox metre axis stays in metres; the room brings a length
//  to nm for the eye, the file does not). A quantity without a number (a refusal) has a nil value and its words in `refusal`.
//

import ImagoCore
import Foundation
import DiffractoGeometry
import ImagoFFT
import SpectroEDX
import SpectroEELS
import ShellEDXModel

package nonisolated struct ResultRow: Sendable, Equatable, Identifiable {
    /// What the room groups by, in the order it lists them. `calibration` and `rings` are the Diffraction room's, `eds` the EDS room's,
    /// `eelsThickness` and `eelsEdges` the EELS room's.
    package enum Group: String, Sendable, Equatable, CaseIterable {
        case marks, spots, calibration, rings, eds, eelsThickness, eelsEdges
    }

    /// What kind of measurement a row is; each has one producer and one validation constant.
    package enum Product: String, Sendable, Equatable, CaseIterable {
        case distance, angle, profile, spot, calibration, ring, edsComposition, eelsThickness, eelsEdge

        package var group: Group {
            switch self {
            case .distance, .angle, .profile: .marks
            case .spot: .spots
            case .calibration: .calibration
            case .ring: .rings
            case .edsComposition: .eds
            case .eelsThickness: .eelsThickness
            case .eelsEdge: .eelsEdges
            }
        }

        /// Between a profile row's two constants.
        package static let profileSamplesClause = "; samples (the Image room's profile CSV): "

        /// The producer's own sentence, verbatim (R-P2).
        package var validation: String {
            switch self {
            case .distance, .angle: ImageMeasurement.validation
            // The row's numbers (length, width, points) are `ImageMeasurement`'s closed forms; the samples the Image room's profile
            // CSV writes are scikit-image's. The sentence says both, each its producer's constant.
            case .profile: ImageMeasurement.validation + Self.profileSamplesClause + ProfileCSV.validation
            case .spot: FFTExport.spotsValidation
            // The kit's own self-reported sentence for the indexing; the calibration's numbers are the kit's closed forms (`RingScaleTests`).
            case .ring: RingIndexing.validation
            case .calibration: "Δq, λ and L are DiffractoKit's closed forms from one ring of a standard's stated lattice constant; not compared with a calibrated camera length"
            // The kit's own constant for an at% or wt% (the cross sections are not checked against a standard of known composition).
            case .edsComposition: Self.edsCompositionLead + PooledQuantification.abundanceValidation
            // SpectroKit reports its EELS validation on each result (`ThicknessMap.validation`, `EELSModelResult.validation`), always "none";
            // each row carries the result's own word as its `validation` entry, and a test holds the two equal.
            case .eelsThickness: Self.eelsThicknessLead + Self.eelsKitValidation
            case .eelsEdge: Self.eelsEdgeLead + Self.eelsKitValidation
            }
        }

        /// The short label of `validation`: what it was checked against, in a few words.
        package var badge: String {
            switch self {
            case .distance, .angle, .profile: "Checked · closed form"
            case .spot: "Checked · planted spots"
            case .calibration: "Checked · closed form"
            case .ring: "Unvalidated · indexing"
            case .edsComposition: "Unvalidated · composition"
            case .eelsThickness: "Unvalidated · thickness"
            case .eelsEdge: "Unvalidated · edge model"
            }
        }

        /// What an EDS row's numbers are, before SpectroKit's validation constant.
        package static let edsCompositionLead = "SpectroKit's pooled quantification of the region's summed spectrum (net counts from the fit; at% and wt% by "
            + "Cliff-Lorimer with the room's k-factors), validation: "

        /// The word SpectroKit's EELS results report as their validation (`ThicknessMap.validation`, `EELSModelResult.validation`).
        package static let eelsKitValidation = "none"

        /// What an EELS thickness row's numbers are, before the kit's validation word.
        package static let eelsThicknessLead = "SpectroKit's log-ratio t/λ (" + EELSThickness.methodName + "): over the whole map the median and quartiles of "
            + "the kit's per-pixel t/λ, and t where λ is set; over a drawn region the t/λ of its summed spectrum; not compared with a sample of known "
            + "thickness, validation: "

        /// What an EELS edge row's numbers are, before the kit's validation word.
        package static let eelsEdgeLead = "SpectroKit's EELS edge model (" + EELSModelFit.methodName + ") of the region's summed spectra: I with the kit's "
            + "1 sigma (counting statistics only, no model error); at% and wt% from the fitted intensities (EELSQuantification.composition, no "
            + "uncertainty given); not compared with a standard, validation: "
    }

    /// One number (or one text) of a row. `value` is nil for a text-only entry.
    package struct Entry: Sendable, Equatable {
        package var name: String
        package var value: Double?
        package var unit: String
        package var text: String

        package init(_ name: String, _ value: Double?, unit: String = "", text: String = "") {
            self.name = name
            self.value = value
            self.unit = unit
            self.text = text
        }
    }

    /// "mark:<UUID>", "spot:<UUID>": stable while the measurement stands.
    package let id: String
    package let product: Product
    /// "Distance 2", "Spot 3".
    package let label: String
    package let entries: [Entry]
    /// Why there is no number, in words; nil for a measurement.
    package let refusal: String?
    /// The mark's node in the session record ("s7"), nil until it has one.
    package let lineage: String?

    package var group: Group { product.group }

    package init(id: String, product: Product, label: String, entries: [Entry], refusal: String? = nil, lineage: String? = nil) {
        self.id = id
        self.product = product
        self.label = label
        self.entries = entries
        self.refusal = refusal
        self.lineage = lineage
    }

    package func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    // MARK: Marks

    /// A distance between two points of the image (`ImageMeasurement.distance`, the FILE's axes).
    package static func distance(id: String, label: String, a: ImagePoint, b: ImagePoint, x: AxisCalibration?, y: AxisCalibration?,
                                 lineage: String?) -> ResultRow {
        let length = ImageMeasurement.distance(a, b, x: x, y: y)
        return ResultRow(id: id, product: .distance, label: label,
                         entries: lengths(length) + points([a, b]), lineage: lineage)
    }

    /// The angle at `vertex` between `a` and `c` (`ImageMeasurement.angle`); an arm of zero length is a refusal.
    package static func angle(id: String, label: String, a: ImagePoint, vertex: ImagePoint, c: ImagePoint, x: AxisCalibration?,
                              y: AxisCalibration?, lineage: String?) -> ResultRow {
        let held = points([a, vertex, c])
        guard let angle = ImageMeasurement.angle(a, vertex: vertex, c, x: x, y: y) else {
            return ResultRow(id: id, product: .angle, label: label, entries: held,
                             refusal: "no angle: an arm has zero length", lineage: lineage)
        }
        let plane = angle.plane == .physical ? "taken in the physical plane" : "taken on the pixel grid"
        return ResultRow(id: id, product: .angle, label: label,
                         entries: [Entry("angle", angle.degrees, unit: "deg", text: plane)] + held, lineage: lineage)
    }

    /// A line profile's line (`ImageMeasurement.distance`) and width; the samples stay in the Image room (`ProfileCSV`).
    package static func profile(id: String, label: String, a: ImagePoint, b: ImagePoint, width: Int, x: AxisCalibration?,
                                y: AxisCalibration?, lineage: String?) -> ResultRow {
        let length = ImageMeasurement.distance(a, b, x: x, y: y)
        return ResultRow(id: id, product: .profile, label: label,
                         entries: lengths(length) + [Entry("width", Double(width), unit: "px")] + points([a, b]),
                         lineage: lineage)
    }

    private static func lengths(_ length: ImageMeasurement.Distance) -> [Entry] {
        var out = [Entry("length_px", length.pixels, unit: "px")]
        if let physical = length.physical, let unit = length.unit { out.append(Entry("length", physical, unit: unit)) }
        return out
    }

    /// x1, y1, x2, y2, ... in image pixels (x column, y row, pixel centres at integers); an angle's vertex is point 2.
    private static func points(_ points: [ImagePoint]) -> [Entry] {
        points.enumerated().flatMap { index, point in
            [Entry("x\(index + 1)", point.x, unit: "px"), Entry("y\(index + 1)", point.y, unit: "px")]
        }
    }

    // MARK: Spots

    /// The region a spot's spectrum was transformed from, in image pixels: its top-left pixel and size.
    package struct Region: Sendable, Equatable {
        package var col: Int, row: Int, width: Int, height: Int

        package init(col: Int, row: Int, width: Int, height: Int) {
            self.col = col
            self.row = row
            self.width = width
            self.height = height
        }
    }

    /// A measured spot (`SpotMeasurement`): d in the image's real unit, |q| and its components in the reciprocal unit.
    package static func spot(id: String, number: Int, measured m: SpotMeasurement, region: Region, lineage: String? = nil) -> ResultRow {
        let neighbour = m.neighbour ? "another peak above 10 % of the spot's power within 3 bins: d may be off by up to 0.3 %" : ""
        let entries = [
            Entry("d", m.d, unit: m.units, text: neighbour),
            Entry("q", m.q, unit: m.reciprocalUnits),
            Entry("qx", m.qx, unit: m.reciprocalUnits),
            Entry("qy", m.qy, unit: m.reciprocalUnits),
            Entry("centroid_col", m.centroidCol, unit: "bin"),
            Entry("centroid_row", m.centroidRow, unit: "bin"),
        ] + clickAndRegion(row: m.clickedRow, col: m.clickedCol, region: region)
        return ResultRow(id: id, product: .spot, label: "Spot \(number)", entries: entries, lineage: lineage)
    }

    /// A spot that was clicked and measured nothing, with the reason: a refusal is a result a reader needs.
    package static func unmeasuredSpot(id: String, number: Int, clickRow: Int, clickCol: Int, region: Region, reason: String,
                                       lineage: String? = nil) -> ResultRow {
        ResultRow(id: id, product: .spot, label: "Spot \(number)",
                  entries: clickAndRegion(row: clickRow, col: clickCol, region: region), refusal: reason, lineage: lineage)
    }

    // MARK: Diffraction

    /// One usable standard fit: the standard and family, the ring's radius, Δq, and what the kit derived from the beam energy.
    package static func calibration(id: String, label: String, standard: String, family: String, d: Double, radius: Double, deltaQ: Double,
                                    wavelength: Double?, lengthPixels: Double?, lengthMM: Double?, fitVersusFilePercent: Double?) -> ResultRow {
        var entries = [Entry("standard", nil, text: "\(standard) \(family)"), Entry("d_listed", d, unit: "Å"), Entry("R", radius, unit: "px"),
                       Entry("delta_q", deltaQ, unit: "1/Å/px")]
        if let wavelength { entries.append(Entry("wavelength", wavelength, unit: "Å")) }
        if let lengthPixels { entries.append(Entry("L_px", lengthPixels, unit: "px")) }
        if let lengthMM { entries.append(Entry("L_mm", lengthMM, unit: "mm")) }
        if let fitVersusFilePercent { entries.append(Entry("fit_vs_file", fitVersusFilePercent, unit: "%")) }
        return ResultRow(id: id, product: .calibration, label: label, entries: entries)
    }

    /// A ring or a spot of a pattern, with the kit's indexing; `refusal` when no number exists.
    package static func ring(id: String, label: String, radius: Double?, q: Double?, d: Double?, family: String?, dListed: Double?,
                             deltaPercent: Double?, odds: String?, verdict: String, refusal: String?) -> ResultRow {
        var entries = [Entry("R", radius, unit: "px"), Entry("q", q, unit: "1/Å"), Entry("d", d, unit: "Å")]
        entries.append(Entry("family", nil, text: family ?? ""))
        entries.append(Entry("d_listed", dListed, unit: "Å"))
        entries.append(Entry("delta", deltaPercent, unit: "%"))
        entries.append(Entry("odds", nil, text: odds ?? ""))
        entries.append(Entry("verdict", nil, text: verdict))
        return ResultRow(id: id, product: .ring, label: label, entries: entries, refusal: refusal)
    }

    // MARK: EDS

    /// SpectroKit's words for a row held at 0 by the fit's bound (`SpectroscopyExport`'s flag, verbatim).
    package static let edsAtBound = "held at 0 by the non-negativity bound: not detected, sigma is an upper-limit scale"

    /// One element of an EDS room's pooled fit of a region (`PooledQuantification.Row`): the net counts with their sigma, and at% and wt%
    /// with theirs when the fit produced them. A row the kit refused carries its words and no number (the kit writes 0 there); an at% the
    /// fit refused carries the fit's reason; a row at the bound carries the kit's flag; the kit's caveat on the at% rows is kept.
    package static func edsComposition(id: String, row: PooledQuantification.Row, regionName: String, abundanceRefusal: String?,
                                       abundanceCaveat: String? = nil) -> ResultRow {
        let line = row.lineNote ?? ""
        let failed = row.failure != nil
        func measured(_ value: Double) -> Double? { failed || !value.isFinite ? nil : value }
        var entries = [Entry("net", measured(row.net), unit: "counts", text: row.atBound && !failed ? edsAtBound : ""),
                       Entry("net_sigma", measured(row.sigma), unit: "counts"),
                       Entry("at", row.atomicPercent, unit: "at%", text: row.atomicPercent == nil ? (abundanceRefusal ?? "") : row.atomicTermsText),
                       Entry("at_sigma", row.atomicSigma, unit: "at%"),
                       Entry("wt", row.weightPercent, unit: "wt%", text: row.weightPercent == nil ? "" : row.weightTermsText),
                       Entry("wt_sigma", row.weightSigma, unit: "wt%"),
                       Entry("line", nil, text: row.groupID)]
        if !line.isEmpty { entries.append(Entry("line_note", nil, text: line)) }
        if let abundanceCaveat, row.atomicPercent != nil { entries.append(Entry("caveat", nil, text: abundanceCaveat)) }
        entries.append(Entry("region", nil, text: regionName))
        return ResultRow(id: id, product: .edsComposition, label: "\(row.element) · \(regionName)", entries: entries, refusal: row.failure)
    }

    // MARK: EELS

    /// The words for a t the room cannot give because no mean free path is set (the EELS room's thickness line).
    package static let eelsNeedsLambda = "t needs λ"
    /// The words for an edge at or under 3 sigma (the EELS room's at% cell and its tooltip).
    package static let eelsBelowDetection = "below detection: I is at or under 3σ, the edge is not detected in this region"
    /// The kit's caveat on I's sigma, as the EELS room's I column says it.
    package static let eelsSigmaCaveat = "± is 1σ from the counts, carried through the background fit (counts taken as Poisson)"
    /// The kit's flag on a fit whose power-law exponent ended on its search bound. The kit flags the fit (any of its edges), not one edge.
    package static let eelsExponentAtBound = "an exponent of this fit ended on a bound of the kit's search range (the kit flags the fit, not which edge)"
    /// A t the kit has nowhere though λ is set.
    package static let eelsNoThickness = "no pixel has a t"

    private static func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }

    /// The whole map's thickness as the EELS room's results line reads it: the median and quartiles of the kit's per-pixel t/λ
    /// (`EELSThicknessStats`), the median t where λ is set, and λ. A map with no t/λ anywhere is a refusal with the kit's reasons; pixels
    /// without one are counted with their reasons.
    package static func eelsWholeMapThickness(id: String, map: ThicknessMap, lambdaSource: String?) -> ResultRow {
        let region = "Whole map"
        let reasons = EELSCompute.unavailableReasons(map).map { "\($0.count) px: \($0.reason)" }.joined(separator: "; ")
        let tail = [Entry("method", nil, text: map.method), Entry("validation", nil, text: map.validation), Entry("region", nil, text: region)]
        guard let stats = EELSThicknessStats.of(map, region: nil) else {
            return ResultRow(id: id, product: .eelsThickness, label: "t/λ · \(region)", entries: tail,
                             refusal: "no pixel has a t/λ" + (reasons.isEmpty ? "" : " (\(reasons))"))
        }
        var entries = [Entry("t_over_lambda", stats.median, text: "median"),
                       Entry("t_over_lambda_q1", stats.q1), Entry("t_over_lambda_q3", stats.q3),
                       Entry("pixels", Double(stats.pixels), unit: "px", text: "with a t/λ"), Entry("pixels_total", Double(stats.total), unit: "px"),
                       Entry("thickness", finite(stats.medianThicknessNM), unit: "nm", text: stats.medianThicknessNM != nil ? "median"
                             : (map.meanFreePathNM == nil ? eelsNeedsLambda : eelsNoThickness)),
                       Entry("mean_free_path", finite(map.meanFreePathNM), unit: "nm", text: map.meanFreePathNM == nil ? "λ not set" : (lambdaSource ?? ""))]
        if !reasons.isEmpty { entries.append(Entry("unavailable", nil, text: reasons)) }
        return ResultRow(id: id, product: .eelsThickness, label: "t/λ · \(region)", entries: entries + tail)
    }

    /// A drawn region's thickness as the EELS room's Regions table reads it: the kit's t/λ of the region's summed low loss, its pixels and
    /// I total. No t/λ is a refusal with the kit's reason.
    package static func eelsRegionThickness(id: String, row: EELSRegionRow, validation: String) -> ResultRow {
        let t = finite(row.tOverLambda)
        let entries = [Entry("t_over_lambda", t, text: "of the summed spectrum"), Entry("pixels", Double(row.pixels), unit: "px"),
                       Entry("i_total", finite(row.totalCounts), unit: "counts"),
                       Entry("validation", nil, text: validation), Entry("region", nil, text: row.pin.name)]
        return ResultRow(id: id, product: .eelsThickness, label: "t/λ · \(row.pin.name)", entries: entries,
                         refusal: t == nil ? (row.tUnavailable ?? "the kit gave no t/λ for the summed spectrum") : nil)
    }

    /// One fitted edge of a region's summed spectra (`EELSEdgeRow`, the EELS room's results table): I and its 1 sigma, the areal density
    /// where the low loss was convolved, at% and wt%, the power-law exponent. An edge the kit could not fit is a refusal with the kit's
    /// reason and no number; an at% the room has not got says why; an edge at or under 3 sigma says it is below detection; the kit's
    /// caveats (the sigma's scope, an exponent at its bound) are kept.
    package static func eelsEdge(id: String, row: EELSEdgeRow, regionName: String, validation: String) -> ResultRow {
        let failed = row.unavailable != nil
        func measured(_ v: Double?) -> Double? { failed ? nil : finite(v) }
        var entries = [Entry("onset", row.onsetEV, unit: "eV"),
                       Entry("intensity", measured(row.intensity)), Entry("intensity_sigma", measured(row.intensityStd)),
                       Entry("areal_density", measured(row.arealDensityPerNM2), unit: "1/nm²"),
                       Entry("at", measured(row.atomicPercent), unit: "at%", text: failed ? "" : (row.atomicUnavailable ?? "")),
                       Entry("wt", measured(row.weightPercent), unit: "wt%"),
                       Entry("exponent_r", measured(row.exponent))]
        if !failed, row.belowDetection { entries.append(Entry("below_detection", nil, text: eelsBelowDetection)) }
        if !failed, row.intensityStd != nil { entries.append(Entry("caveat", nil, text: eelsSigmaCaveat)) }
        if !failed, row.exponentAtBound { entries.append(Entry("exponent_at_bound", nil, text: eelsExponentAtBound)) }
        entries += [Entry("edge", nil, text: row.title), Entry("validation", nil, text: validation), Entry("region", nil, text: regionName)]
        return ResultRow(id: id, product: .eelsEdge, label: "\(row.title) · \(regionName)", entries: entries, refusal: row.unavailable)
    }

    /// A drawn region whose edge fit the kit refused as a whole (a window on its summed core loss, a sum it could not make): one row with the
    /// kit's words, so the region's edges are not silently missing.
    package static func eelsRegionEdgesRefused(id: String, regionName: String, reason: String, validation: String) -> ResultRow {
        ResultRow(id: id, product: .eelsEdge, label: "Edges · \(regionName)",
                  entries: [Entry("validation", nil, text: validation), Entry("region", nil, text: regionName)], refusal: reason)
    }

    private static func clickAndRegion(row: Int, col: Int, region: Region) -> [Entry] {
        [Entry("click_col", Double(col), unit: "bin"), Entry("click_row", Double(row), unit: "bin"),
         Entry("region_col", Double(region.col), unit: "px"), Entry("region_row", Double(region.row), unit: "px"),
         Entry("region_width", Double(region.width), unit: "px"), Entry("region_height", Double(region.height), unit: "px")]
    }

    /// The words for a refused click (the estimator's own failures).
    package static func reason(_ failure: SpotMeasurementError) -> String {
        switch failure {
        case .nearDC: "not measured: the peak nearest the click is within 3 bins of the centre"
        case .nearEdge: "not measured: the peak nearest the click is within 2 bins of the edge"
        case .mixedUnits: "not measured: the axes are in different units"
        case .crop: "not measured: the region does not lie inside the image"
        case .fftSetup(let width, let height): "not measured: the Fourier transform of \(width) x \(height) px could not be set up"
        case .outside: "not measured: the click is outside the spectrum"
        case .zeroFrequency: "not measured: one of the spots is at the zero frequency"      // the kit's angle between two spots; the room never asks
        case .nonFinite: "not measured: the image holds a NaN or an infinity, so its spectrum is not defined"   // ImagoKit 0.6.0
        case .noPower: "not measured: no power in the window once its mean is removed (a constant image or region)"   // ImagoKit 0.6.0
        }
    }

    /// The words ImagoKit 0.5 gave a click whose estimator answered with no number. No outcome produces it since ImagoKit 0.6.0 refuses
    /// by name (`.noPower`, `.nonFinite`); kept for the ledger's pinned wording in `ResultsCSVTests`.
    package static let noPeak = "not measured: no peak here, the power near the click is zero or not finite"
}
