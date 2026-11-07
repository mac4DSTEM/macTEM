//
//  SEMMethod.swift
//  Role: the methods of the SEM rooms as the session report cites them and the Results room's Info tab names them: a short title (the
//        Method column), one sentence on what the method does here, its literature, and the reference package the parity tests hold
//        it to (`tools/parity/sem`, docs/parity.md). The EELS room's `EELSLiterature` pattern for the SEM program (design
//        export-and-reports §4, item 6; D-SEM-103).
//
//        The references are the ones the ported files and docs/parity.md already name; the versions are `SEMReferenceVersions`'.
//

import Foundation

package nonisolated enum SEMMethod: String, Sendable, Equatable, CaseIterable, Identifiable {
    case patternReading
    case staticBackground, dynamicBackground, intensity, equalisation, fftFilter, binning, neighbourAveraging, nlpar
    case virtualBSE, imageQuality, averageDotProduct
    case houghIndexing, dictionaryIndexing, orientationSimilarity, kikuchiOverlay
    case orientationMap, ipfColours
    case angWriter, ctfWriter
    case edsLines, cliffLorimer

    package var id: String { rawValue }

    /// The Method column's words.
    package var title: String {
        switch self {
        case .patternReading: "Pattern file reader"
        case .staticBackground: "Static background"
        case .dynamicBackground: "Dynamic background"
        case .intensity: "Intensity rescale"
        case .equalisation: "CLAHE"
        case .fftFilter: "FFT filter"
        case .binning: "Binning"
        case .neighbourAveraging: "Neighbour averaging"
        case .nlpar: "NLPAR"
        case .virtualBSE: "Virtual BSE imaging"
        case .imageQuality: "Image quality"
        case .averageDotProduct: "Average dot product"
        case .houghIndexing: "Hough indexing"
        case .dictionaryIndexing: "Dictionary indexing"
        case .orientationSimilarity: "Orientation similarity map"
        case .kikuchiOverlay: "Kikuchi overlay"
        case .orientationMap: "Crystal map"
        case .ipfColours: "IPF colour key"
        case .angWriter: "EDAX .ang writer"
        case .ctfWriter: "Oxford .ctf writer"
        case .edsLines: "Line intensities"
        case .cliffLorimer: "Cliff-Lorimer"
        }
    }

    /// What the method does in the app, one sentence.
    package var sentence: String {
        switch self {
        case .patternReading:
            "The patterns, the scan's steps, the detector and the projection centres read as kikuchipy reads the file, header and patterns exact."
        case .staticBackground:
            "The static background (the file's, or the scan's mean pattern) subtracted from or divided into every pattern, as kikuchipy's EBSD.remove_static_background does."
        case .dynamicBackground:
            "Each pattern's own background, a Gaussian blur of it, removed as kikuchipy's EBSD.remove_dynamic_background does."
        case .intensity:
            "The intensities rescaled to the data type's range or normalised to zero mean and a set standard deviation, as kikuchipy's EBSD.rescale_intensity and EBSD.normalize_intensity do."
        case .equalisation:
            "Contrast-limited adaptive histogram equalisation of each pattern, as kikuchipy's EBSD.adaptive_histogram_equalization (scikit-image's equalize_adapthist) does."
        case .fftFilter:
            "Each pattern filtered in the frequency domain with Gaussian-edged low-pass and high-pass transfer functions, as kikuchipy's EBSD.fft_filter does."
        case .binning:
            "The patterns binned by a whole factor, as kikuchipy's EBSD.downsample does."
        case .neighbourAveraging:
            "Each pattern averaged with its neighbours in the scan under a window, as kikuchipy's EBSD.average_neighbour_patterns does."
        case .nlpar:
            "Non-local pattern averaging: each pattern averaged with the patterns of its search window that look like it, weighted by their similarity, with the smoothing λ chosen per scan, as pyEBSDindex's NLPAR does."
        case .virtualBSE:
            "Virtual backscatter electron images: the intensity of chosen detector tiles summed per pattern, and three tiles mixed into one colour image, as kikuchipy's VirtualBSEImager does."
        case .imageQuality:
            "The image quality of each pattern from its power spectrum, as kikuchipy's EBSD.get_image_quality does."
        case .averageDotProduct:
            "The average normalised dot product of each pattern with its four nearest neighbours, as kikuchipy's EBSD.get_average_neighbour_dot_product_map does."
        case .houghIndexing:
            "Bands found in each pattern by the Radon transform, triplets of bands voted against the phase's reflectors, the orientation fitted by QUEST, as pyEBSDindex's EBSDIndexer does when kikuchipy's EBSD.hough_indexing drives it."
        case .dictionaryIndexing:
            "Every pattern compared with patterns simulated from a master pattern on a cubochoric sampling of orientations, the best matches kept by normalised cross-correlation or dot product, as kikuchipy's EBSD.dictionary_indexing does."
        case .orientationSimilarity:
            "For each point, how many of its best dictionary matches its neighbours share, as kikuchipy's orientation_similarity_map does."
        case .kikuchiOverlay:
            "The Kikuchi bands of the point's indexed orientation drawn on its pattern, the band centres and the edges at the Bragg angle, as kikuchipy's KikuchiPatternSimulator draws a geometrical simulation."
        case .orientationMap:
            "The orientations, phases and properties of each point held as orix's CrystalMap, the Euler angles in Bunge's convention."
        case .ipfColours:
            "Each orientation coloured by the direction it puts along the sample axis, in the TSL key of its phase's Laue group, as orix's IPFColorKeyTSL does."
        case .angWriter:
            "The crystal map written as an EDAX TSL .ang file (Euler angles in radians, the phases' symmetry and lattice in the header), as orix's .ang writer writes it."
        case .ctfWriter:
            "The crystal map written as an Oxford HKL Channel 5 .ctf file (Euler angles in degrees), read back by orix's .ctf reader."
        case .edsLines:
            "The X-ray line intensities of the spectrum summed over each line's window, with the background estimated from windows on either side, as exspy's get_lines_intensity does."
        case .cliffLorimer:
            "The weight and atomic fractions from the line intensities and k-factors by the Cliff-Lorimer ratio method, as exspy's quantification does."
        }
    }

    /// The literature, as docs/parity.md and the ported files cite it.
    package var references: [String] {
        switch self {
        case .patternReading:
            [Self.kikuchipy]
        case .staticBackground, .dynamicBackground, .intensity, .binning:
            [Self.anes2020, Self.kikuchipy]
        case .equalisation:
            ["Zuiderveld 1994, in Graphics Gems IV, 474", Self.kikuchipy]
        case .fftFilter:
            [Self.anes2020, Self.kikuchipy]
        case .neighbourAveraging:
            ["Wright, Nowell, Lindeman, Camus, De Graef and Jackson 2015, Ultramicroscopy 159, 81", Self.kikuchipy]
        case .nlpar:
            ["Brewick, Wright and Rowenhorst 2019, Ultramicroscopy 200, 50", Self.pyebsdindex]
        case .virtualBSE:
            ["Wright, Nowell, de Kloe, Camus and Rampton 2015, Ultramicroscopy 148, 132", Self.kikuchipy]
        case .imageQuality:
            ["Krieger Lassen 1994, PhD thesis, Technical University of Denmark", Self.kikuchipy]
        case .averageDotProduct:
            ["Brewick, Wright and Rowenhorst 2019, Ultramicroscopy 200, 50", Self.kikuchipy]
        case .houghIndexing:
            ["Krieger Lassen 1994, PhD thesis, Technical University of Denmark (Radon transform)",
             "Wright and Adams 1992, Metall. Trans. A 23, 759 (triplet voting)",
             "Shuster and Oh 1981, J. Guid. Control 4, 70 (QUEST)",
             Self.pyebsdindex]
        case .dictionaryIndexing:
            ["Chen et al. 2015, Microsc. Microanal. 21, 739",
             "Jackson, Pascal and De Graef 2019, Integr. Mater. Manuf. Innov. 8, 226",
             "Callahan and De Graef 2013, Microsc. Microanal. 19, 1255 (master patterns)",
             "Roşca, Morawiec and De Graef 2014, Modelling Simul. Mater. Sci. Eng. 22, 075013 (cubochoric sampling)",
             "Singh and De Graef 2016, Modelling Simul. Mater. Sci. Eng. 24, 085013",
             Self.kikuchipy]
        case .orientationSimilarity:
            ["Marquardt et al. 2017, as kikuchipy's orientation_similarity_map cites it", Self.kikuchipy]
        case .kikuchiOverlay:
            [Self.kikuchipy]
        case .orientationMap:
            ["Rowenhorst et al. 2015, Modelling Simul. Mater. Sci. Eng. 23, 083501 (rotation conventions)", Self.orix]
        case .ipfColours:
            ["Nolze and Hielscher 2016, J. Appl. Cryst. 49, 1786", Self.orix]
        case .angWriter, .ctfWriter:
            [Self.orix]
        case .edsLines:
            [Self.exspy]
        case .cliffLorimer:
            ["Cliff and Lorimer 1975, J. Microsc. 103, 203", Self.exspy]
        }
    }

    /// The pinned package the parity tests hold the port to, with its version (`SEMReferenceVersions`).
    package var parityReference: String {
        switch self {
        case .patternReading, .staticBackground, .dynamicBackground, .intensity, .equalisation, .fftFilter, .binning, .neighbourAveraging,
             .virtualBSE, .imageQuality, .averageDotProduct, .orientationSimilarity:
            SEMReferenceVersions.label("kikuchipy")
        case .nlpar:
            SEMReferenceVersions.label("pyebsdindex")
        case .houghIndexing:
            SEMReferenceVersions.label("pyebsdindex") + " as " + SEMReferenceVersions.label("kikuchipy") + " drives it"
        case .dictionaryIndexing:
            SEMReferenceVersions.label("kikuchipy") + " and " + SEMReferenceVersions.label("orix")
        case .kikuchiOverlay:
            SEMReferenceVersions.label("kikuchipy") + " and " + SEMReferenceVersions.label("diffsims")
        case .orientationMap, .ipfColours, .angWriter, .ctfWriter:
            SEMReferenceVersions.label("orix")
        case .edsLines, .cliffLorimer:
            SEMReferenceVersions.label("exspy")
        }
    }

    static let kikuchipy = "kikuchipy: Ånes et al., Zenodo, doi:10.5281/zenodo.3597646"
    static let pyebsdindex = "PyEBSDIndex: Rowenhorst, Callahan and Ånes 2024, J. Appl. Cryst. 57, 3"
    static let orix = "orix: Johnstone et al. 2020, J. Appl. Cryst. 53, 1293"
    static let exspy = "exspy, HyperSpy's EDS and EELS package (github.com/hyperspy/exspy)"
    static let anes2020 = "Ånes, Hjelen, Sørensen, van Helvoort and Marthinsen 2020, IOP Conf. Ser.: Mater. Sci. Eng. 891, 012002"
}

/// The pinned reference packages of `tools/parity/sem` (its `requirements.lock`; a unit test holds the two equal), the versions the
/// parity tests compared the ports against.
package nonisolated enum SEMReferenceVersions {
    /// Name and version, in the lock's spelling, in the order the report lists them.
    package static let pinned: [(name: String, version: String)] = [
        ("kikuchipy", "0.13.1"),
        ("orix", "0.15.0"),
        ("pyebsdindex", "0.3.10.1"),
        ("diffsims", "0.7.0"),
        ("hyperspy", "2.5.0"),
        ("exspy", "0.3.2"),
        ("rosettasciio", "0.15.0"),
        ("defdap", "1.3.1"),
        ("numpy", "2.5.4"),
    ]

    /// The Swift packages the app is built with, name and version, as `Package.resolved` pins them (a unit test holds the two equal, so
    /// a kit update changes this list in the same pull request). The report's Versions section lists them.
    package static let builtWith: [SEMSessionField] = [
        SEMSessionField("FormatoKit", "0.12.1"),
        SEMSessionField("ImagoKit", "0.9.1"),
        SEMSessionField("DiffractoKit", "0.11.0"),
        SEMSessionField("SpectroKit", "0.13.2"),
        SEMSessionField("MacEMUI", "0.5.1"),
    ]

    /// "kikuchipy 0.13.1"; the bare name when the package is not pinned.
    package static func label(_ name: String) -> String {
        guard let version = pinned.first(where: { $0.name == name })?.version else { return name }
        return "\(name) \(version)"
    }
}
