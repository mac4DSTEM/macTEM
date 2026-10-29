//
//  ImageRoomSession.swift
//  Role: the tail of the Image room's Measure section (V1-2 slice B's UI, archive: v12-session-ui-design-2026-10-14.md,
//        sections 1 and 2): where the marks are kept, said in words — "Not saved", "Restored from …", "Saved at …", why a
//        session file was not used — with Save to Session when something changed, Show in Finder and Choose Session File…
//        where the design puts them. It replaces the note "Marks stay while the file is open; they are not saved yet." The
//        reason a Save is off is drawn here, never only in the menu (mac4DSTEM's drive 14 shipped a dimmed Save with none).
//
//        Presentation only: the state is the item's (`OpenItem`, `ImageMeasurements`, TEMSession); what the tail SAYS is
//        `SessionFormat`, pure so a test pins every sentence; the actions are `SessionPanels` (App/, which holds the
//        AppKit panels). The Save row is omitted when clean, never dimmed (export's rule), and is its own row, not beside
//        Remove All.
//

import ShellInspector
import SwiftUI
import UniformTypeIdentifiers
import TEMCore
import TEMSession

// MARK: - The words

/// What the tail needs to decide its words: values, so a test can build every state.
struct SessionTailInput: Equatable {
    /// The session file's name (`scan.dm4.mactem.h5`), nil when none can be named.
    var fileName: String?
    var sidecar: ImageMeasurements.Sidecar
    var notes: [ImageMeasurements.Note]
    var needsAccess: Bool
    /// The lineage version of a file written by a newer macTEM, else nil.
    var newerVersion: Int?
    var hasMarks: Bool
    var isDirty: Bool
    var canSave: Bool
    var isSaving: Bool
    var savedAt: Date?
    /// Why the next mark would not be recorded (`ImageMeasurements.recordingRefusal`: the record is full, or at the
    /// session file's byte budget), else nil.
    var recording: SessionLineage.Refusal? = nil
}

/// One line of the tail.
nonisolated struct SessionTailLine: Equatable, Identifiable {
    enum Kind: Equatable { case warning(symbol: String), note }
    let kind: Kind
    let text: String
    /// The words themselves: a line keeps its identity when another appears or goes (a position would hand its state to
    /// the wrong line), and no two lines of a tail say the same thing.
    var id: String { text }
}

/// What the tail draws.
nonisolated struct SessionTail: Equatable {
    var lines: [SessionTailLine] = []
    var showsSave = false
    var showsFinder = false
    /// Choose Session File…: nil = not offered; otherwise the reason it is off, or "" when it is on.
    var chooseFile: String?
}

enum SessionFormat {
    static func tail(_ input: SessionTailInput, locale: Locale = .autoupdatingCurrent) -> SessionTail {
        let name = input.fileName ?? "the session file"
        var tail = SessionTail()
        if input.needsAccess {
            tail.lines = [
                .init(kind: .warning(symbol: "lock.fill"),
                      text: "A session file for this image is beside it, but macOS has not given macTEM access to read it."),
                .init(kind: .note, text: "Saving is off until you choose it, so its marks are not overwritten."),
            ]
            tail.chooseFile = input.hasMarks ? "Remove the marks drawn here to restore the session file's marks." : ""
            return tail
        }
        if let version = input.newerVersion {
            tail.lines = [
                .init(kind: .warning(symbol: "exclamationmark.triangle.fill"),
                      text: "\(name) was written by a newer macTEM (lineage version \(version)); its marks are not shown."),
                .init(kind: .note, text: savingOff(name, refused: false)),
            ]
            tail.showsFinder = true
            return tail
        }
        if case .refused(let reason) = input.sidecar {
            tail.lines = [
                .init(kind: .warning(symbol: "exclamationmark.triangle.fill"), text: "\(name) was not used."),
                .init(kind: .note, text: capitalised(reason)),
                .init(kind: .note, text: savingOff(name, refused: true)),
            ]
            tail.showsFinder = true
            return tail
        }

        // The state line: where the marks are kept.
        if input.isSaving {
            tail.lines.append(.init(kind: .note, text: "Saving…"))
        } else {
            switch input.sidecar {
            case .none:
                if input.hasMarks {
                    tail.lines.append(.init(kind: .note, text:
                        "Not saved. Save to Session (⌘S) keeps the marks in \(name), beside the image."))
                }
            case .restored:
                tail.lines.append(.init(kind: .note, text: input.isDirty
                    ? "Changed since restored from \(name)." : "Restored from \(name)."))
            case .saved:
                let at = input.savedAt.map { " at " + $0.formatted(.dateTime.hour().minute().locale(locale)) } ?? ""
                tail.lines.append(.init(kind: .note, text: input.isDirty
                    ? "Changed since saved\(at)." : "Saved\(at) to \(name)."))
            case .refused:
                break
            }
        }
        for note in input.notes {
            switch note {
            case .pixelsDiffer:
                tail.lines.append(.init(kind: .warning(symbol: "exclamationmark.triangle.fill"), text:
                    "The image differs from when the marks were drawn. The values shown are measured on this image."))
            case .renamed(let old):
                tail.lines.append(.init(kind: .note, text:
                    "This session file was saved for “\(old)”; the image is the same."))
            case .calibrationDiffers:
                tail.lines.append(.init(kind: .warning(symbol: "exclamationmark.triangle.fill"), text:
                    "The image's calibration differs from when the marks were measured."))
            }
        }
        if let refusal = input.recording {
            tail.lines.append(.init(kind: .warning(symbol: "exclamationmark.triangle.fill"),
                                    text: MarkRefusalText.standing(refusal)))
        }
        tail.showsSave = input.canSave && !input.isSaving
        return tail
    }

    /// The Replace alert's two sentences, for a session file another app changed since this window read it.
    static func replaceTitle(name: String) -> String { "\(name) has changed since this window read it." }
    static func replaceDetail(name: String) -> String {
        "Another app wrote it. Replace it with the marks in this window, or cancel and keep it as it is. "
            + "Replacing loses what the other file holds."
    }

    /// The infobar's line after Choose Session File…, by what became of the file (never "chosen" for a file that did nothing).
    static func chosenLine(_ outcome: SidecarOutcome, adopted: Bool, name: String) -> String {
        switch outcome {
        case .none: "No session file was found at that place."
        case .needsAccess: "macOS has not given macTEM access to \(name)."
        case .refused: "\(name) was not used."
        case .restored: adopted ? "Restored the marks from \(name)"
            : "The marks in \(name) were not restored: marks are already drawn in this window. Remove them first."
        }
    }

    private static func savingOff(_ name: String, refused: Bool) -> String {
        refused
            ? "Saving to \(name) is off, so the file is never overwritten. Marks drawn here stay in this window."
            : "Saving to \(name) is off, so the file is never rewritten."
    }

    static func capitalised(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

// MARK: - A mark the record would not take

/// What is said when the session record cannot take a mark, a move or a width (ADR 023 a: the saved text is at most 60,000
/// bytes; the record also holds at most 2,000 entries): in plain words, what happened and what to do. Pure, so a test pins
/// every sentence. Never a silent no-op: the gesture's caller shows `refused`, and the Measure tail shows `standing`
/// while the next mark would be refused.
nonisolated enum MarkRefusalText {
    enum Action: Equatable { case added, moved, widthChanged }

    private static func opening(_ action: Action) -> String {
        switch action {
        case .added: "The mark was not added."
        case .moved: "The mark was not moved."
        case .widthChanged: "The width was not changed."
        }
    }

    /// The alert's text for a gesture the record refused. `refusal` nil is the budget (the only reason a move or a width
    /// is refused: a longer number costs bytes).
    static func refused(_ refusal: SessionLineage.Refusal?, _ action: Action) -> String {
        let limit = SessionSidecarFile.maxTotalTextBytes
        switch refusal {
        case .tooLargeToSave(let bytes, let limit):
            return "\(opening(action)) With it the session record would take \(bytes.formatted()) bytes of text, over the "
                + "\(limit.formatted()) a session file holds. Remove a mark to make room."
        case nil:
            return "\(opening(action)) With it the session record would take more than the \(limit.formatted()) bytes of text "
                + "a session file holds. Remove a mark to make room."
        case .tooManyNodes, .idsExhausted:
            return "\(opening(action)) The session record is full: it holds \(SessionLineage.maximumNodes.formatted()) entries, "
                + "removed marks included. To start a new record, move the session file aside and open the image again."
        case .notFinite:
            return "\(opening(action)) A point of it is not a number."
        case .some(let other):
            return "\(opening(action)) \(other.reason.prefix(1).uppercased() + other.reason.dropFirst())."
        }
    }

    /// The Measure tail's line while the next mark would be refused.
    static func standing(_ refusal: SessionLineage.Refusal) -> String {
        switch refusal {
        case .tooLargeToSave(let bytes, let limit):
            "The session record is full: another mark would take it to \(bytes.formatted()) bytes of text, over the "
                + "\(limit.formatted()) a session file holds. Remove a mark to draw another."
        case .tooManyNodes, .idsExhausted:
            "The session record is full: it holds \(SessionLineage.maximumNodes.formatted()) entries, removed marks included. "
                + "To start a new record, move the session file aside and open the image again."
        default:
            "No more marks can be recorded: \(refusal.reason)."
        }
    }
}

// MARK: - The view

/// The tail: reads the item's state once and draws `SessionFormat`'s lines, then the buttons.
struct ImageRoomSessionTail: View {
    let item: OpenItem
    @Environment(AppState.self) private var appState
    @State private var choosing = false

    var body: some View {
        // One read of each, here.
        let tail = SessionFormat.tail(SessionTailInput(item: item))
        ForEach(tail.lines) { line in
            switch line.kind {
            case .warning(let symbol): InspectorWarning(line.text, systemImage: symbol)
            case .note: InspectorNote(line.text)
            }
        }
        if tail.showsSave || tail.showsFinder || tail.chooseFile != nil {
            InspectorActionRow {
                if tail.showsSave {
                    Button(SessionGrants.bookmark(forSource: item.url) == nil ? "Save to Session…" : "Save to Session") { SessionPanels.save(appState: appState) }
                        .help("Keep the marks in the session file beside the image (⌘S)")
                }
                if tail.showsFinder {
                    Button("Show in Finder") { SessionPanels.showInFinder(item) }
                }
                if let reason = tail.chooseFile {
                    Button("Choose Session File…") { choosing = true }
                        .disabled(!reason.isEmpty)
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await SessionPanels.restoreChosen(url, into: item, appState: appState) }
            }
            .fileDialogDefaultDirectory(item.url.deletingLastPathComponent())
            .fileDialogMessage("Choose \(item.sessionFileName ?? "the session file") to restore the marks drawn on "
                               + "\(item.url.lastPathComponent).")
            .fileDialogConfirmationLabel("Restore")
            if let reason = tail.chooseFile, !reason.isEmpty { InspectorNote(reason) }
        }
    }
}
