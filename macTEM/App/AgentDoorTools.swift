//
//  AgentDoorTools.swift
//  Role: macTEM's half of the agent door (MacEMUI's `ShellAgentDoor`, docs/agent-door.md there): the door this app opens and the
//        tools it hands it. Read-only: each tool looks at what the window shows and answers; none changes the app.
//
//        ONE SOURCE PER FACT: the picture is Export Image…'s own (`ExportSnapshot.imageSnapshot` into `ImageExport.render`: the
//        display window, colormap, scale bar and marks as the file exports them), made smaller when it is large; the results are
//        Export Results…'s CSV (`ResultsCSV.text`). Nothing here draws or computes a number of its own.
//
//        Each window (a tab is a window) enrols with its `AppState`; the door names them `w1`, `w2`, ... Every tool looks at the
//        file its window shows (`openItems.selected`), as an export does. The switch is in Settings > Agents (`AgentSettingsView`).
//

import CoreGraphics
import Foundation
import ImageIO
import ImagoCore
import ShellAgentDoor
import ShellLayout
import TEMCore
import TEMSession

enum MacTEMAgentDoor {
    /// The app's one door. Opened by the Settings switch, and at launch when it was left on.
    static let shared: AgentDoor = {
        let door = AgentDoor(appName: "macTEM", appVersion: version())
        door.register(MacTEMAgentDoor.tools)
        return door
    }()

    /// The preference behind Settings > Agents: off until the person turns it on.
    static let enabledKey = "prefs.agentDoorEnabled"

    /// A picture's longest side at scale 1; scale 2 and 3 allow twice and three times as much. An agent judges a figure, it does
    /// not measure from it: a 4096² export is tens of MB.
    static let pictureSide = 1024

    nonisolated static func version(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        info?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Enrols a window and opens the door when the person left it on (never in a UI-testing launch).
    static func start(with appState: AppState, defaults: UserDefaults = .standard) {
        shared.enroll(appState) { MacTEMAgentDoor.summary(of: appState) }
        guard !appState.launch.isUITesting else { return }
        shared.setEnabled(defaults.bool(forKey: enabledKey))
    }

    /// A window closed: the door forgets it.
    static func withdraw(_ appState: AppState) {
        shared.withdraw(appState)
    }

    // MARK: Tools

    static let tools: [AgentTool] = [
        AgentTool(name: "get_window", title: "Window state",
                  summary: "What one macTEM window shows: the room, the open files (the shown one first in its row), each file's size, "
                      + "calibration and voltage once read, how many finished results the shown file has, and the status line.",
                  input: .window) { call in
            guard let appState = call.window?.state as? AppState else { return MacTEMAgentDoor.notAWindow }
            return .json(MacTEMAgentDoor.window(appState))
        },
        AgentTool(name: "get_image", title: "Image picture",
                  summary: "The shown file's image as Export Image… draws it: its display window, gamma and colormap, the scale bar "
                      + "when shown and the marks (distances, angles, profiles). Longest side up to 1024 pixels per scale step.",
                  input: .windowPicture) { call in
            guard let appState = call.window?.state as? AppState else { return MacTEMAgentDoor.notAWindow }
            return MacTEMAgentDoor.image(appState, scale: call.scale)
        },
        AgentTool(name: "get_results", title: "Results",
                  summary: "The shown file's finished measurements as Export Results… writes them (CSV): marks, diffraction calibration "
                      + "and rings, EDS composition, EELS thickness and edges, each with its unit, uncertainty and source.",
                  input: .window) { call in
            guard let appState = call.window?.state as? AppState else { return MacTEMAgentDoor.notAWindow }
            return MacTEMAgentDoor.results(appState)
        },
        AgentTool(name: "get_log", title: "Output log",
                  summary: "The window's Output lines, oldest first: what was read, what ran, what was refused and why.",
                  input: .window) { call in
            guard let appState = call.window?.state as? AppState else { return MacTEMAgentDoor.notAWindow }
            return .json(["lines": appState.activityLog.messages])
        },
    ]

    private static let notAWindow = AgentToolOutput.refusal(status: 500, message: "That window is not a macTEM window.")

    // MARK: Answers

    /// `list_windows`' line: the shown file and the room.
    static func summary(of appState: AppState) -> [String: Any] {
        [
            "file_name": AgentJSON.orNull(appState.openItems.selected.map { $0.url.lastPathComponent }),
            "room": appState.navigation.workspaceArea.title,
            "open_files": appState.openItems.items.count,
        ]
    }

    static func window(_ appState: AppState) -> [String: Any] {
        let selected = appState.openItems.selected
        return [
            "room": appState.navigation.workspaceArea.title,
            "shown_file": AgentJSON.orNull(selected.map { $0.url.lastPathComponent }),
            "files": appState.openItems.items.map { file($0, shown: $0 === selected) },
            "results": selected.map { appState.resultRows(of: $0).count } ?? 0,
            "status": appState.statusText,
            "error": AgentJSON.orNull(appState.errorMessage),
        ]
    }

    static func file(_ item: OpenItem, shown: Bool) -> [String: Any] {
        var line: [String: Any] = ["name": item.url.lastPathComponent, "shown": shown]
        switch item.residency {
        case .reading: line["state"] = "reading"
        case .resident: line["state"] = "read"
        case .cold: line["state"] = "set aside (read again when shown)"
        }
        guard let image = item.session.image else { return line }
        line["width"] = image.width
        line["height"] = image.height
        line["object"] = image.source
        line["x_calibration"] = calibration(image.x)
        line["y_calibration"] = calibration(image.y)
        line["voltage_volts"] = AgentJSON.number(image.voltage)
        line["notes"] = image.notes
        return line
    }

    /// An axis as the file states it: units per pixel and the unit; null for a file without one (positions are then in pixels).
    nonisolated static func calibration(_ axis: AxisCalibration?) -> Any {
        guard let axis else { return NSNull() }
        return ["per_pixel": AgentJSON.number(axis.scale), "unit": axis.unit]
    }

    static func image(_ appState: AppState, scale: Int) -> AgentToolOutput {
        guard let snapshot = ExportSnapshot.imageSnapshot(in: appState.openItems) else {
            return .refusal(status: 404, message: "No image is shown: open a file in macTEM, or wait until its read finishes.")
        }
        let options = ExportSnapshot.options(scaleBar: snapshot.defaults.scaleBar, marks: snapshot.defaults.marks,
                                             offersMarks: snapshot.defaults.offersMarks)
        do {
            let rendered = try ImageExport.render(source: snapshot.source, display: snapshot.display, marks: snapshot.marks, options: options)
            return .png(smaller(rendered.png, side: pictureSide * scale) ?? rendered.png)
        } catch {
            return .refusal(status: 500, message: "The image could not be drawn: \(error.localizedDescription)")
        }
    }

    /// The PNG with its longest side at most `side`; nil when it already fits or ImageIO cannot make it smaller.
    nonisolated static func smaller(_ png: Data, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > side else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return AgentJSON.png(thumbnail)
    }

    static func results(_ appState: AppState) -> AgentToolOutput {
        guard let snapshot = ExportSnapshot.resultsSnapshot(in: appState),
              let csv = ResultsCSV.text(snapshot.rows, source: snapshot.source, session: snapshot.session) else {
            return .refusal(status: 404, message: "The shown file has no finished result yet.")
        }
        return .json(["file_name": snapshot.source.fileName, "rows": snapshot.rows.count, "csv": csv])
    }
}
