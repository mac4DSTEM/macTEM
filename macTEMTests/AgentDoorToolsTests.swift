// macTEM's agent tools (`MacTEMAgentDoor`): what they answer for an empty window and for a window showing a file, that the picture
// is Export Image…'s own and is made smaller only when large, and that the door stays shut until the person opens it. The door
// itself (listener, token, routes) is tested in MacEMUI (ShellAgentDoorTests).

import CoreGraphics
import Foundation
import ImageIO
import ImagoCore
import ShellAgentDoor
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class AgentDoorToolsTests: XCTestCase {

    private func plantedCopy() throws -> URL {
        let source = try XCTUnwrap(Bundle(for: AgentDoorToolsTests.self).url(forResource: "planted-2d", withExtension: "dm4"),
                                   "planted-2d.dm4 is not in the test bundle")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactem-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("planted.dm4")
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private static func size(ofPNG data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    @MainActor func testTheToolsAreTheFourThatLook() {
        XCTAssertEqual(MacTEMAgentDoor.tools.map(\.name), ["get_window", "get_image", "get_results", "get_log"])
        XCTAssertEqual(MacTEMAgentDoor.shared.appName, "macEM")
    }

    /// An empty window says so, and the picture and the results are refused with a sentence, not an empty answer.
    @MainActor func testAnEmptyWindowSaysItHoldsNothing() {
        let state = AppState()
        let window = MacTEMAgentDoor.window(state)
        XCTAssertEqual(window["room"] as? String, "Image")
        XCTAssertTrue(window["shown_file"] is NSNull)
        XCTAssertEqual((window["files"] as? [[String: Any]])?.count, 0)
        guard case .refusal(let status, let message) = MacTEMAgentDoor.image(state, scale: 1) else { return XCTFail("a picture of nothing") }
        XCTAssertEqual(status, 404)
        XCTAssertTrue(message.contains("No image is shown"))
        guard case .refusal(let none, _) = MacTEMAgentDoor.results(state) else { return XCTFail("results of nothing") }
        XCTAssertEqual(none, 404)
    }

    /// A window showing a file: the file's line names it with its size, and the picture is Export Image…'s at the image's own size.
    /// Red under: the picture drawn from anything but the export snapshot (another size), or the shown file not marked.
    @MainActor func testAWindowShowingAFileDescribesItAndDrawsItAsTheExport() async throws {
        let url = try plantedCopy()
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [url])?.value
        await state.openItems.settled()
        let image = try XCTUnwrap(state.imageSession.image, "the planted file did not open")

        let window = MacTEMAgentDoor.window(state)
        XCTAssertEqual(window["shown_file"] as? String, "planted.dm4")
        let file = try XCTUnwrap((window["files"] as? [[String: Any]])?.first)
        XCTAssertEqual(file["shown"] as? Bool, true)
        XCTAssertEqual(file["state"] as? String, "read")
        XCTAssertEqual(file["width"] as? Int, image.width)
        XCTAssertEqual(file["height"] as? Int, image.height)
        XCTAssertEqual(MacTEMAgentDoor.summary(of: state)["file_name"] as? String, "planted.dm4")

        guard case .png(let png) = MacTEMAgentDoor.image(state, scale: 1) else { return XCTFail("no picture") }
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let snapshot = try XCTUnwrap(ExportSnapshot.imageSnapshot(in: state.openItems))
        let exported = try ImageExport.render(source: snapshot.source, display: snapshot.display, marks: snapshot.marks,
                                              options: ExportSnapshot.options(scaleBar: snapshot.defaults.scaleBar, marks: snapshot.defaults.marks,
                                                                                     offersMarks: snapshot.defaults.offersMarks))
        if max(image.width, image.height) <= MacTEMAgentDoor.pictureSide {
            XCTAssertEqual(png, exported.png, "a picture that fits is the export, byte for byte")
        }
        XCTAssertFalse((MacTEMAgentDoor.summary(of: state)["room"] as? String ?? "").isEmpty)
    }

    /// Large pictures are made smaller to the asked side; one that fits is left alone.
    func testAPictureIsMadeSmallerOnlyWhenLarge() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let png = try XCTUnwrap(AgentJSON.png(try XCTUnwrap(context.makeImage())))
        XCTAssertNil(MacTEMAgentDoor.smaller(png, side: 300), "it fits")
        let smaller = try XCTUnwrap(MacTEMAgentDoor.smaller(png, side: 150))
        let size = try XCTUnwrap(Self.size(ofPNG: smaller))
        XCTAssertEqual(size.width, 150)
        XCTAssertEqual(size.height, 100)
    }

    func testCalibrationIsTheFilesOwnOrNull() {
        XCTAssertTrue(MacTEMAgentDoor.calibration(nil) is NSNull)
        let axis = MacTEMAgentDoor.calibration(AxisCalibration(scale: 0.25, unit: "nm")) as? [String: Any]
        XCTAssertEqual(axis?["per_pixel"] as? Double, 0.25)
        XCTAssertEqual(axis?["unit"] as? String, "nm")
        XCTAssertEqual(MacTEMAgentDoor.version(info: ["CFBundleShortVersionString": "1.2.3"]), "1.2.3")
    }

    /// The door is shut until the person turns it on: a window that appears with the preference unset leaves it off.
    @MainActor func testTheDoorStaysShutUntilThePersonOpensIt() throws {
        let suite = "mactem-agent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(launch: LaunchOptions(arguments: []))
        MacTEMAgentDoor.start(with: state, defaults: defaults)
        defer { MacTEMAgentDoor.shared.withdraw(state) }
        XCTAssertEqual(MacTEMAgentDoor.shared.status, .off)
        XCTAssertFalse(defaults.bool(forKey: MacTEMAgentDoor.enabledKey))
    }
}
