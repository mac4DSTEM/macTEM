//
//  GuardedXMLTests.swift
//  The one loader of the XML a file carries (FormatoCore's GuardedXML, moved there from Sources/TEMCore/Data at FormatoKit 0.3.0; Gate B 2026-10-12, found by the
//  review of archive: roadmap-registrations-2026-10-15.md V1-4a slice S-a). Its two callers, `AcquisitionMetadata.tiff` and `TIFFImageReader.read`, read a
//  Velox TIFF's tag 34683 through it, and each test below runs the same document through the loader and through both
//  callers: a refused document reads as no tag (nothing recorded; uncalibrated) and a document that passes reads as it
//  always did. The planted truth is the document written here; the documents are built in memory.
//
//  Every test names the production mutation that turns it red. A mutation that is a crash when the check is gone
//  (50,000 levels of nesting) says so: its graceful twin is the 65-level case that fails by returning a value.
//

import ImagoCore
import XCTest
import TEMCore
// swiftlint:disable duplicate_imports
// swiftformat:disable:next duplicateImports
import enum FormatoCore.GuardedXML
// swiftlint:enable duplicate_imports
import FormatoCore
import FormatoTIFF
@testable import macTEM

nonisolated final class GuardedXMLTests: XCTestCase {

    // MARK: A real-shaped document passes

    func testARealShapedVeloxDocumentPassesAndBothCallersReadIt() throws {
        // The shape of the owner's Ceta tags (Talos F200X): an xmlns attribute, six levels, about a thousand characters of
        // short texts, a predefined entity, a numeric character reference, a CDATA section and a comment. Mutations that
        // turn this red (each run 2026-10-12): a bound too tight for it (maxDepth 5, maxCharacters 100), a pre-pass that
        // refuses on any "&" (the predefined entity and the character reference), on "xmlns", on a comment, or on a
        // CDATA section.
        let properties = (0..<30).map { "<Property>value \($0) of the custom properties</Property>" }.joined()
        let xml = Self.document(extra: "<!-- a comment -->" + properties
                                    + "<Scan><Group><Item><Sub><Leaf><![CDATA[<kept & raw>]]></Leaf></Sub></Item></Group></Scan>",
                                model: "Talos &amp; F200X &#181;")
        XCTAssertNil(GuardedXML.refusal(xml))
        let document = try XCTUnwrap(GuardedXML.document(xml))
        XCTAssertEqual(try document.nodes(forXPath: "/Metadata/Scan/Group/Item/Sub/Leaf").first?.stringValue, "<kept & raw>")
        let (metadata, image) = try Self.read(xml)
        XCTAssertEqual(metadata.highTensionKV?.value, 200)
        XCTAssertEqual(metadata.instrument?.value, "Talos & F200X \u{B5}")
        XCTAssertEqual(metadata.detector?.value, "BM-Ceta")
        XCTAssertEqual(metadata.exposureS?.value, 2)
        XCTAssertEqual(image.x, AxisCalibration(scale: 1.6e-09, unit: "m", origin: 0))
    }

    // MARK: Nesting

    func testNestingPastSixtyFourLevelsIsRefusedAndTheLimitItselfPasses() throws {
        // Depth counts the root: 64 nested elements pass, 65 do not. Mutations that turn this red: the depth check
        // removed (65 levels pass the pre-pass, and both callers then read the 200 kV beside them); the comparison made
        // `>=` (64 levels are refused); maxDepth changed.
        XCTAssertNil(GuardedXML.refusal(Self.nested(64)))
        XCTAssertEqual(GuardedXML.refusal(Self.nested(65)), .depth)
        XCTAssertNil(GuardedXML.document(Self.nested(65)))
        let passing = try Self.read(Self.document(extra: Self.nestedInside(63)))     // <Metadata> and 63 inside: 64 levels
        XCTAssertEqual(passing.metadata.highTensionKV?.value, 200)
        XCTAssertNotNil(passing.image.x)
        let refused = try Self.read(Self.document(extra: Self.nestedInside(65)))
        XCTAssertTrue(refused.metadata.isEmpty, "a refused document records nothing, 200 kV beside the nesting included")
        XCTAssertNil(refused.image.x, "and calibrates nothing")
        XCTAssertEqual(refused.image.pixels.count, 4, "the pixels are never refused for an unreadable calibration")
    }

    func testFiftyThousandLevelsAreRefusedOnABackgroundThread() throws {
        // The crash the review measured: 50,000 levels end the process on the main thread and 5,000 on a secondary thread
        // (512 KiB of stack) in the unguarded XMLDocument. Mutation that turns this red: the depth check removed — the
        // process then dies (a signal: 10 here) rather than failing an assertion; the 65-level test above is the graceful
        // twin. The work runs off the main thread as the app's open path does.
        let xml = Self.document(extra: String(repeating: "<a>", count: 50_000) + String(repeating: "</a>", count: 50_000))
        let outcome = Self.onASecondaryThread { () -> (Bool, Bool, GuardedXML.Refusal?) in
            let result = try? Self.read(xml)
            return (result?.metadata.isEmpty ?? false, result?.image.x == nil, GuardedXML.refusal(xml))
        }
        XCTAssertEqual(outcome.0, true, "nothing recorded")
        XCTAssertEqual(outcome.1, true, "uncalibrated")
        XCTAssertEqual(outcome.2, .depth)
    }

    // MARK: Entities

    func testABillionLaughsDocumentIsRefusedBeforeItExpands() throws {
        // Six levels of ten references each: 10^6 expansions of "lol" (3 MB) here; the review measured ten levels as
        // 2.35 s and 9.4 GB from 747 bytes. Mutation that turns this red: the internal entity callback removed (the
        // pre-pass no longer says .entity; the expansion is stopped, if at all, by the character budget or not until the
        // tree is built — with the budget removed as well it expands in full).
        var declarations = ["<!ENTITY l0 \"lol\">"]
        for level in 1...6 { declarations.append("<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">") }
        let xml = Self.document(doctype: "<!DOCTYPE Metadata [" + declarations.joined() + "]>", model: "&l6;")
        XCTAssertEqual(GuardedXML.refusal(xml), .entity)
        let result = try Self.read(xml)
        XCTAssertTrue(result.metadata.isEmpty)
        XCTAssertNil(result.image.x)
    }

    func testEvenOneSmallDeclaredEntityRefusesTheDocument() throws {
        // A declared entity can only be used to expand, so none is read at all. Mutations that turn this red: the internal
        // callback removed (the first and third declarations are then no reason to refuse and the 200 kV beside them is
        // read); the unparsed callback removed (the second). The third is a PARAMETER entity, which Foundation reports as
        // an internal one.
        for declaration in ["<!ENTITY s \"x\">",
                            "<!NOTATION n SYSTEM \"n\"><!ENTITY s SYSTEM \"file:///nonexistent\" NDATA n>",
                            "<!ENTITY % p \"<!ENTITY q 'zz'>\">"] {
            let xml = Self.document(doctype: "<!DOCTYPE Metadata [\(declaration)]>")
            XCTAssertEqual(GuardedXML.refusal(xml), .entity, declaration)
            XCTAssertTrue(try Self.read(xml).metadata.isEmpty, declaration)
        }
        // A DOCTYPE that declares no entity is no reason to refuse, and the predefined entities read.
        XCTAssertNil(GuardedXML.refusal(Self.document(doctype: "<!DOCTYPE Metadata [<!ELEMENT Metadata ANY>]>", model: "a &lt; b")))
    }

    func testADeclaredExternalEntityRefusesTheDocumentOnTheTree() throws {
        // Foundation's SAX parser reports no external entity declaration while external entities are unresolved (measured
        // 2026-10-12, macOS 27 SDK; the header of FormatoKit's GuardedXML.swift says so), so the pre-pass passes these documents and
        // `document` refuses them after building the tree, from the DTD's entity declarations. Mutations that turn this
        // red: that DTD check removed (the document is read: 200 kV, and an unloaded entity reads as empty text). The
        // `refusal == nil` assertions are also a tripwire on the SDK: if a later one reports the declaration, they are
        // to be changed on purpose and the tree check stays as the second look.
        for declaration in ["<!ENTITY s SYSTEM \"file:///nonexistent\">", "<!ENTITY s PUBLIC \"-//x\" \"file:///nonexistent\">"] {
            let xml = Self.document(doctype: "<!DOCTYPE Metadata [\(declaration)]>", model: "a&s;b")
            XCTAssertNil(GuardedXML.refusal(xml), "the SAX pass sees no declaration: \(declaration)")
            XCTAssertNil(GuardedXML.document(xml), declaration)
            let result = try Self.read(xml)
            XCTAssertTrue(result.metadata.isEmpty, "the 200 kV beside the declaration is not shown either: \(declaration)")
            XCTAssertNil(result.image.x, declaration)
        }
    }

    func testAnExternalEntityIsNeverOpenedNotEvenToBeRefused() throws {
        // Building the tree opens a file that a SYSTEM entity names, unless told not to: a hostile tag could name /dev/zero,
        // a pipe, a slow mount or a URL, and be refused only after the read. A named pipe detects the open: a writer blocks
        // in open(2) until somebody opens the pipe for reading (measured: with XMLDocument's default options the writer
        // is released, with `.nodeLoadExternalEntitiesNever` it is not). Mutation that turns this red: GuardedXML.document
        // building the tree with the default options (the DTD check still refuses the document, so only this test sees it).
        let path = NSTemporaryDirectory() + "v14a-fifo-\(UUID().uuidString)"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { unlink(path) }
        let released = DispatchSemaphore(value: 0)
        let writer = Thread {
            let descriptor = open(path, O_WRONLY)              // blocks until a reader opens the pipe
            if descriptor >= 0 { close(descriptor) }
            released.signal()
        }
        writer.start()
        Thread.sleep(forTimeInterval: 0.05)
        let url = URL(fileURLWithPath: path).absoluteString
        let xml = Self.document(doctype: "<!DOCTYPE Metadata [<!ENTITY s SYSTEM \"\(url)\">]>", model: "&s;")
        XCTAssertNil(GuardedXML.document(xml))
        let opened = released.wait(timeout: .now() + 0.3) == .success
        XCTAssertFalse(opened, "something opened the file the entity names")
        if !opened {                                            // let the writer's open(2) return, then join it
            let reader = open(path, O_RDONLY | O_NONBLOCK)
            if reader >= 0 { close(reader) }
            released.wait()
        }
    }

    func testALaughsDocumentWrittenInUTF7IsRefusedAsAnEntityNotAsText() throws {
        // A textual scan for <!DOCTYPE or <!ENTITY cannot be the defence: this document contains neither string (asserted
        // below) and an unguarded XMLDocument expanded it (the review measured a 30 MB value from it). The refusal must be
        // for the ENTITY, not for a parse failure: the pass decodes UTF-7 as the tree parser does. Mutations that turn
        // this red: the entity-declaration callbacks removed; the pre-pass replaced by a scan of the text for
        // "<!ENTITY" (the text has none, so the document passes).
        var declarations = ["<!ENTITY l0 \"lol\">"]
        for level in 1...6 { declarations.append("<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">") }
        let body = "<!DOCTYPE Metadata [" + declarations.joined() + "]><Metadata><Optics><AccelerationVoltage>200000"
            + "</AccelerationVoltage></Optics><BinaryResult><Detector>&l6;</Detector></BinaryResult></Metadata>"
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-7\"?>" + Self.utf7(body)
        XCTAssertFalse(xml.contains("<!DOCTYPE"))
        XCTAssertFalse(xml.contains("<!ENTITY"))
        XCTAssertEqual(xml.filter { $0 == "<" }.count, 1, "the only < is the prolog's")
        XCTAssertEqual(GuardedXML.refusal(xml), .entity)
        let result = try Self.read(xml)
        XCTAssertTrue(result.metadata.isEmpty)
        XCTAssertNil(result.image.x)
    }

    // MARK: Length

    func testMoreThanAMebibyteOfTextIsRefusedWhereverItSits() throws {
        // Mutations that turn this red: the character budget removed (each document below passes and the 200 kV is
        // read); the budget not counting CDATA (the CDATA document passes); the budget counted per element instead of
        // over the whole document (the many-elements document passes); the comparison made `>=` (exactly 1 MiB is refused).
        let mebibyte = 1 << 20
        func blob(_ count: Int) -> String {       // exactly `count` characters of text, in one element
            "<?xml version=\"1.0\"?><Metadata><Blob>" + String(repeating: "x", count: count) + "</Blob></Metadata>"
        }
        XCTAssertNil(GuardedXML.refusal(blob(mebibyte)), "exactly 1 MiB passes")
        XCTAssertEqual(GuardedXML.refusal(blob(mebibyte + 1)), .characters)
        let cdata = "<Blob><![CDATA[" + String(repeating: "x", count: mebibyte + 1) + "]]></Blob>"
        XCTAssertEqual(GuardedXML.refusal(Self.document(extra: cdata)), .characters)
        let many = (0..<21).map { _ in "<Part>" + String(repeating: "x", count: 50_000) + "</Part>" }.joined()
        XCTAssertEqual(GuardedXML.refusal(Self.document(extra: many)), .characters, "21 × 50,000 characters, none of them long alone")
        for xml in [Self.document(extra: "<Blob>" + String(repeating: "x", count: mebibyte + 1) + "</Blob>"),
                    Self.document(extra: cdata), Self.document(extra: many)] {
            let result = try Self.read(xml)
            XCTAssertTrue(result.metadata.isEmpty, "the 200 kV beside the long text is not shown either")
            XCTAssertNil(result.image.x)
        }
    }

    func testATagOverFourMebibytesIsRefusedBeforeItIsParsed() throws {
        // A comment is not text, so only the size bound sees this document. Mutations that turn this red: the size check
        // removed (the document passes and both callers read it); the comparison made `>=` (exactly 4 MiB is refused).
        func padded(to bytes: Int) -> String {
            let base = Self.document(extra: "<!---->")
            return Self.document(extra: "<!--" + String(repeating: "x", count: bytes - base.utf8.count) + "-->")
        }
        let limit = 4 * 1024 * 1024
        XCTAssertEqual(padded(to: limit).utf8.count, limit)
        XCTAssertNil(GuardedXML.refusal(padded(to: limit)), "exactly 4 MiB passes")
        XCTAssertEqual(GuardedXML.refusal(padded(to: limit + 1)), .size)
        let over = try Self.read(padded(to: limit + 1))
        XCTAssertTrue(over.metadata.isEmpty)
        XCTAssertNil(over.image.x)
        let atTheLimit = try Self.read(padded(to: limit))
        XCTAssertEqual(atTheLimit.metadata.highTensionKV?.value, 200)
        XCTAssertNotNil(atTheLimit.image.x)
    }

    func testAStringValueOverTwoHundredFiftySixCharactersIsNotRecorded() throws {
        // `bounded` counts characters, not bytes: 256 two-byte characters read and 257 plain ones do not. Mutations that
        // turn this red: the cap removed (the 257-character values are read); the cap measured in UTF-8 bytes (the
        // 256 two-byte characters are 512 bytes and read as absent); the cap not applied to the Detectors/* children (the
        // 257-character exposure is read).
        XCTAssertEqual(GuardedXML.bounded(String(repeating: "\u{E9}", count: 256)), String(repeating: "\u{E9}", count: 256))
        XCTAssertNil(GuardedXML.bounded(String(repeating: "x", count: 257)))
        XCTAssertNil(GuardedXML.bounded(nil))
        let fits = String(repeating: "\u{E9}", count: 256), tooLong = String(repeating: "x", count: 257)
        let kept = try Self.read(Self.document(detector: fits, model: fits)).metadata
        XCTAssertEqual(kept.detector?.value, fits)
        XCTAssertEqual(kept.instrument?.value, fits)
        let dropped = try Self.read(Self.document(detector: tooLong, model: tooLong)).metadata
        XCTAssertNil(dropped.detector)
        XCTAssertNil(dropped.instrument)
        XCTAssertNil(dropped.exposureS, "no detector name to match, so no exposure either")
        XCTAssertEqual(dropped.highTensionKV?.value, 200, "the rest of the document is read")
        // The mode is a short word too, and an exposure a short number: 257 characters of either read as absent.
        XCTAssertNil(try Self.read(Self.document(mode: tooLong)).metadata.mode)
        XCTAssertEqual(try Self.read(Self.document(exposure: "2" + String(repeating: "0", count: 255))).metadata.exposureS?.value, 2e255,
                       "256 characters of number read")
        XCTAssertNil(try Self.read(Self.document(exposure: "2" + String(repeating: "0", count: 256))).metadata.exposureS,
                     "257 do not (a number of that length is no exposure, parseable or not)")
    }

    // MARK: The other caller

    func testTIFFImageReaderRefusesWhatTheMetadataReaderRefuses() throws {
        // The calibration reads the same tag through the same loader. The pixel size below is given by a declared entity
        // (read by an unguarded XMLDocument as 1e-9); with the DOCTYPE removed it calibrates. Mutation that turns this red:
        // TIFFImageReader.velox loading the XML with `XMLDocument(xmlString:options:)` again, as it did before 2026-10-12
        // (the entity-valued PixelSize is then read and the image calibrates).
        let pixel = "<PixelSize><X unit=\"m\">&s;</X><Y unit=\"m\">&s;</Y></PixelSize>"
        let declared = "<?xml version=\"1.0\"?><!DOCTYPE Metadata [<!ENTITY s \"1e-9\">]><Metadata><BinaryResult>\(pixel)</BinaryResult></Metadata>"
        XCTAssertNil(try TIFFImageReader.read(data: XMLTIFF(xml: declared).build(), fileName: "declared.tif").x,
                     "a refused XML is no pixel size: uncalibrated")
        let plain = "<?xml version=\"1.0\"?><Metadata><BinaryResult><PixelSize><X unit=\"m\">1e-9</X><Y unit=\"m\">1e-9</Y></PixelSize></BinaryResult></Metadata>"
        XCTAssertEqual(try TIFFImageReader.read(data: XMLTIFF(xml: plain).build(), fileName: "plain.tif").x,
                       AxisCalibration(scale: 1e-9, unit: "m", origin: 0))
    }

    // MARK: Helpers

    /// A Ceta-shaped document: every part is optional. `doctype` follows the XML declaration; `extra` goes last inside
    /// <Metadata>; `detector`, `model` and `mode` are the text of those elements.
    private static func document(doctype: String = "", extra: String = "", detector: String = "BM-Ceta",
                                 model: String = "Talos F200X", mode: String = "TEM", exposure: String = "2") -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + doctype
            + "<Metadata xmlns:nil=\"http://schemas.fei.com/Metadata/v1/2013/07\">"
            + "<Instrument><InstrumentModel>\(model)</InstrumentModel></Instrument>"
            + "<Acquisition><AcquisitionStartDatetime>2026-06-05T13:05:31.000</AcquisitionStartDatetime></Acquisition>"
            + "<Optics><AccelerationVoltage>200000</AccelerationVoltage><OperatingMode>\(mode)</OperatingMode></Optics>"
            + "<Detectors><ImagingDetector><DetectorName>\(detector)</DetectorName><ExposureTime>\(exposure)</ExposureTime></ImagingDetector></Detectors>"
            + "<BinaryResult><Detector>\(detector)</Detector><PixelSize><X unit=\"m\">1.6e-09</X><Y unit=\"m\">1.6e-09</Y></PixelSize></BinaryResult>"
            + extra + "</Metadata>"
    }

    /// `levels` nested elements counting the root: <Metadata><a><a>…</a></a></Metadata> with `levels` − 1 inner ones.
    private static func nested(_ levels: Int) -> String {
        "<?xml version=\"1.0\"?><Metadata>" + String(repeating: "<a>", count: levels - 1)
            + String(repeating: "</a>", count: levels - 1) + "</Metadata>"
    }

    /// `levels` nested elements to put inside <Metadata> (so a `document` holding them is `levels` + 1 deep or more).
    private static func nestedInside(_ levels: Int) -> String {
        String(repeating: "<a>", count: levels) + String(repeating: "</a>", count: levels)
    }

    /// Both callers on one document: the acquisition values and the calibrated image.
    private static func read(_ xml: String) throws -> (metadata: AcquisitionMetadata, image: CalibratedImage) {
        let data = XMLTIFF(xml: xml).build()
        return (try AcquisitionMetadata.tiff(data: data, convention: .app), try TIFFImageReader.read(data: data, fileName: "guarded.tif"))
    }

    /// UTF-7 (RFC 2152) by the rule that matters here: letters, digits, space and ' ( ) , - . / : ? are written as
    /// themselves and everything else as "+" base64 of its UTF-16BE code units "-", so no "<" survives.
    private static func utf7(_ text: String) -> String {
        let direct = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '(),-./:?")
        return text.map { character -> String in
            if direct.contains(character) { return String(character) }
            let units = String(character).utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            return "+" + Data(units).base64EncodedString().replacingOccurrences(of: "=", with: "") + "-"
        }.joined()
    }

    /// `body` on a thread with the default secondary-thread stack (512 KiB), waiting for its result.
    private static func onASecondaryThread<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { box.value = body(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return box.value!
    }
}

/// The result of work on another thread, read after the semaphore says it is written.
private nonisolated final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

/// A 2 × 2 grey TIFF whose only extra tag is 34683 holding `xml`: what both callers need to read.
private nonisolated struct XMLTIFF {
    var xml: String

    func build() -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        let text = Array(xml.utf8) + [0]
        // header (8) | four pixels (8..11) | IFD (12) | the XML after the IFD
        let entries: [(tag: Int, type: Int, count: Int, value: Int)] = [
            (256, 4, 1, 2), (257, 4, 1, 2), (258, 3, 1, 8), (262, 3, 1, 1), (273, 4, 1, 8), (277, 3, 1, 1),
            (278, 4, 1, 2), (279, 4, 1, 4), (284, 3, 1, 1), (339, 3, 1, 1), (34683, 2, text.count, 12 + 2 + 12 * 11 + 4),
        ]
        var out: [UInt8] = [0x49, 0x49] + u16(42) + u32(12) + [1, 2, 3, 4] + u16(entries.count)
        for entry in entries { out += u16(entry.tag) + u16(entry.type) + u32(entry.count) + u32(entry.value) }
        out += u32(0) + text
        return Data(out)
    }
}
