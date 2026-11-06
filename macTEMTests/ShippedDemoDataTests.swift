//
//  ShippedDemoDataTests.swift
//  The real, licensed files the app bundle ships as demo data (`DemoDocuments.Shipped`, DemoData/, NOTICE): each is in the built bundle at
//  the size and md5 its source publishes, its contents read back to the truth h5py gave (readers are tested exact), and the SEM-EDS
//  spectrum opens through the app's own route into the EDS room. A replaced or truncated file, a lost folder reference in the Xcode
//  project, or a `.hspy` that no longer routes goes red here.
//

import XCTest
import FormatoHDF5
import SpectroCore
import TEMCore
import TEMSession
@testable import macTEM
import ShellEDXModel

nonisolated final class ShippedDemoDataTests: XCTestCase {

    /// Every shipped file is in the bundle (the `DemoData` folder reference copies the whole folder) at the pinned size and md5.
    /// Mutation: a file replaced, truncated or renamed; the folder reference dropped from the project.
    func testEveryShippedFileIsInTheBundleAtItsPinnedSizeAndMD5() throws {
        XCTAssertEqual(DemoDocuments.Shipped.all.count, 2)
        for file in DemoDocuments.Shipped.all {
            let url = try XCTUnwrap(file.url, "\(file.relativePath) is not in the bundle's DemoData/")
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertEqual(size, file.bytes, file.relativePath)
            XCTAssertEqual(try DemoDocuments.md5(of: url), file.md5, file.relativePath)
            XCTAssertEqual(url.lastPathComponent, file.fileName)
        }
    }

    /// The nickel patterns: 55 x 75 of 60 x 60 uint8 at kikuchipy's path, the header agreeing, the first pattern's pixel sum as h5py read it.
    func testTheNickelPatternsReadBackToTheirTruth() throws {
        let file = DemoDocuments.Shipped.nickelEBSD
        let url = try XCTUnwrap(file.url)
        let reader = try HDF5Reader(url: url)
        let info = try reader.datasetInfo(DemoDocuments.Shipped.nickelEBSDPatternsPath)
        XCTAssertEqual(info.shape, [DemoDocuments.Shipped.nickelEBSDRows * DemoDocuments.Shipped.nickelEBSDColumns,
                                    DemoDocuments.Shipped.nickelEBSDPatternHeight, DemoDocuments.Shipped.nickelEBSDPatternWidth])
        XCTAssertEqual(info.type, .numeric(.uint8))
        XCTAssertEqual(try reader.readDataset("/Scan 1/EBSD/Header/n_rows").doubles(), [Double(DemoDocuments.Shipped.nickelEBSDRows)])
        XCTAssertEqual(try reader.readDataset("/Scan 1/EBSD/Header/n_columns").doubles(), [Double(DemoDocuments.Shipped.nickelEBSDColumns)])
        let first = try reader.readDataset(DemoDocuments.Shipped.nickelEBSDPatternsPath, start: [0, 0, 0], count: [1, 60, 60]).doubles()
        XCTAssertEqual(first.count, 3600)
        XCTAssertEqual(UInt64(first.reduce(0, +)), DemoDocuments.Shipped.nickelEBSDFirstPatternSum)
        let all = try reader.readDataset(DemoDocuments.Shipped.nickelEBSDPatternsPath).doubles()
        XCTAssertEqual(all.count, 4125 * 3600)
        XCTAssertEqual(UInt64(all.reduce(0, +)), DemoDocuments.Shipped.nickelEBSDPixelSum)
    }

    /// The BAM TM002 spectrum through the HyperSpy reader: 1024 channels of 0.01 keV from -0.1 keV, 10 kV, the counts exact (their total,
    /// the peak channel), the microscope and the five elements the file names.
    func testTheSEMEDSSpectrumReadsBackToItsTruth() throws {
        let url = try XCTUnwrap(DemoDocuments.Shipped.semEDSSpectrum.url)
        XCTAssertTrue(HyperSpySpectrumFile.isHyperSpyFile(path: url.path))
        let header = try HyperSpySpectrumFile.header(path: url.path)
        XCTAssertEqual(header.experiment, "/Experiments/EDS SEM Spectrum")
        XCTAssertEqual(header.title, "EDS SEM Spectrum")
        XCTAssertEqual(header.channels, DemoDocuments.Shipped.semEDSChannels)
        let spectrum = try HyperSpySpectrumFile.read(path: url.path)
        XCTAssertEqual(spectrum.counts.count, DemoDocuments.Shipped.semEDSChannels)
        XCTAssertEqual(spectrum.offset, DemoDocuments.Shipped.semEDSOffsetKeV, accuracy: 1e-12)
        XCTAssertEqual(spectrum.scale, DemoDocuments.Shipped.semEDSScaleKeV, accuracy: 1e-12)
        XCTAssertEqual(spectrum.units, "keV")
        XCTAssertEqual(spectrum.signalType, "EDS_SEM")
        XCTAssertEqual(spectrum.beamEnergyKeV, DemoDocuments.Shipped.semEDSBeamKeV)
        XCTAssertEqual(spectrum.microscope, "Nvision40 Carl Zeiss")
        XCTAssertEqual(spectrum.elements, DemoDocuments.Shipped.semEDSElements)
        XCTAssertEqual(UInt64(spectrum.counts.reduce(0, +)), DemoDocuments.Shipped.semEDSTotalCounts)
        let peak = try XCTUnwrap(spectrum.counts.indices.max { spectrum.counts[$0] < spectrum.counts[$1] })
        XCTAssertEqual(peak, DemoDocuments.Shipped.semEDSPeakChannel)
        XCTAssertEqual(UInt32(spectrum.counts[peak]), DemoDocuments.Shipped.semEDSPeakCounts)
    }

    /// The route: a `.hspy` of one spectrum is a single spectrum (the EDS room), opens as a one-pixel spectrum image with the file's axis,
    /// beam energy and instrument, and its extension is one the Open panel and Finder offer. A `.hspy` that is not HDF5 is refused in words.
    func testTheSpectrumRoutesToTheEDSRoomAsAOnePixelImage() throws {
        let url = try XCTUnwrap(DemoDocuments.Shipped.semEDSSpectrum.url)
        XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(singleSpectrum: true))
        XCTAssertTrue(FileRouting.isSingleSpectrum(path: url.path))
        XCTAssertTrue(EDXOpening.isSpectrumImage(at: url))
        let loaded = try FileRouting.spectrumFile(path: url.path)
        XCTAssertEqual(loaded.metadata.scanWidth, 1); XCTAssertEqual(loaded.metadata.scanHeight, 1)
        XCTAssertEqual(loaded.metadata.channelCount, 1024)
        XCTAssertEqual(loaded.metadata.beamEnergyKeV, 10)
        XCTAssertEqual(loaded.metadata.instrument, "Nvision40 Carl Zeiss")
        XCTAssertEqual(loaded.energyAxis.offset, -0.1, accuracy: 1e-9); XCTAssertEqual(loaded.energyAxis.scale, 0.01, accuracy: 1e-9)
        XCTAssertEqual(loaded.metadata.energyOffsetEV, -100, accuracy: 1e-6); XCTAssertEqual(loaded.metadata.energyDispersionEV, 10, accuracy: 1e-6)
        XCTAssertEqual(loaded.image.sum(mask: nil).reduce(0, +), DemoDocuments.Shipped.semEDSTotalCounts)
        XCTAssertTrue(FileRouting.openableExtensions.contains("hspy"))
        XCTAssertTrue(EDXOpening.readableExtensions.contains("hspy"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hspy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("fake.hspy")
        try Data("not an HDF5 file".utf8).write(to: fake)
        XCTAssertFalse(HyperSpySpectrumFile.isHyperSpyFile(path: fake.path))
        XCTAssertEqual(FileRouting.inventory(path: fake.path).refusal, "fake.hspy is not a format macTEM opens (or its extension and its first bytes disagree).")
    }

    /// Help > Open Demo Data and `--demo-sem-eds` open the shipped spectrum into the EDS room through the app's own Open.
    @MainActor func testTheSpectrumOpensFromTheMenuAndTheLaunchArgument() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.openDemo(.semSpectrum)?.value
        XCTAssertEqual(state.navigation.workspaceArea, .edx)
        XCTAssertTrue(state.edx.hasImage || state.edx.isOpening, "the EDS room holds the spectrum or is opening it")
        XCTAssertTrue(LaunchOptions(arguments: ["--demo-sem-eds"]).demoSEMSpectrum)
        XCTAssertFalse(LaunchOptions(arguments: []).demoSEMSpectrum)
    }
}
