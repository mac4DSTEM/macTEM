//
//  ErrorDetailTests.swift
//  The words an error is shown in (`ErrorDetail.text`): a system error keeps its sentence and adds its Cocoa domain, code and
//  underlying error, so a sandbox denial (NSPOSIXErrorDomain 1) and a missing file read apart; the app's own errors read as they
//  are written. The SEM-EDS readers' "could not be read" and "could not be opened" carry the reason. The missing files are named in
//  a fresh temporary folder, removed after the test.
//  Red before: no `ErrorDetail` (`AppState.present` showed only the sentence), and a missing .spc, .spx or .bcf said only "could
//  not be read." or "could not be opened."
//

import XCTest
import TEMCore

nonisolated final class ErrorDetailTests: XCTestCase {

    /// A file name in a fresh temporary folder that holds nothing, the folder removed after the test.
    private func missing(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mactem-errordetail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent(name)
    }

    /// The reader's sentence for `body`'s refusal, or "" when it threw something else or nothing.
    private func refusal(_ body: () throws -> Void) -> String {
        do { try body() } catch { return (error as? SEMEDSReadError)?.text ?? "" }
        return ""
    }

    /// Red under: the domain and code left out; the underlying error left out; an app error's bridged type name and enum index added.
    func testASystemErrorKeepsItsDomainCodeAndUnderlyingError() {
        let denied = CocoaError(.fileReadNoPermission, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1)])
        let text = ErrorDetail.text(denied)
        XCTAssertTrue(text.contains("NSPOSIXErrorDomain 1"), text)
        XCTAssertTrue(text.hasSuffix(" (NSCocoaErrorDomain 257; underlying NSPOSIXErrorDomain 1)"), "the sentence first: \(text)")

        let gone = ErrorDetail.text(NSError(domain: NSPOSIXErrorDomain, code: 2))
        XCTAssertTrue(gone.contains("(NSPOSIXErrorDomain 2)"), gone)

        XCTAssertEqual(ErrorDetail.text(SEMEDSReadError("scan.spd ends before its data.")), "scan.spd ends before its data.")
        XCTAssertEqual(ErrorDetail.text(EBSDReadError(text: "scan.h5 holds no patterns.")), "scan.h5 holds no patterns.")
    }

    /// A file that is not there: each reader's sentence names the system's reason (its domain at least), where it said only "could not
    /// be read." Red under: a reader's catch block dropping the error again.
    func testTheEDSReadersSayWhyAFileCouldNotBeRead() throws {
        let spc = try missing("gone.spc")
        let spcText = refusal { _ = try EDAXEDSReader.read(url: spc) }
        XCTAssertTrue(spcText.hasPrefix("gone.spc could not be read: "), spcText)
        XCTAssertTrue(spcText.contains("ErrorDomain"), spcText)

        let spx = try missing("gone.spx")
        let spxText = refusal { _ = try BrukerEDSReader.read(url: spx) }
        XCTAssertTrue(spxText.hasPrefix("gone.spx could not be read: "), spxText)
        XCTAssertTrue(spxText.contains("ErrorDomain"), spxText)

        let bcf = try missing("gone.bcf")
        let bcfText = refusal { _ = try BrukerSFS(url: bcf) }
        XCTAssertTrue(bcfText.hasPrefix("gone.bcf could not be opened: "), bcfText)
        XCTAssertTrue(bcfText.contains("ErrorDomain"), bcfText)
    }
}
