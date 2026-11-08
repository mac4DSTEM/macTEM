//
//  CloseGuard.swift
//  Role: what closing a file or quitting would lose, asked before it is lost: the files whose marks are not saved to their
//        session file (`ImageMeasurements.isDirty`) and, at quit, the rooms still working (an indexing run, a fit, a map being
//        drawn). The sentences are pure (`CloseGuard`); the window's close requests are `AppState`'s, below. Close Image (⌘W and
//        the toolbar's Image menu), ⌫ in Open Files and a row's Close and Close Others go through `requestClose`: a file with
//        nothing unsaved closes at once, as before; otherwise the files stay open until the answer (`closeRequest`, asked as a
//        sheet by `SessionPanels.askToClose`). Quitting asks in `AppDelegate`.
//

import Foundation
import ShellEDXModel
import TEMSession

/// The rule and its words, pure so a test pins them.
nonisolated enum CloseGuard {

    /// What the user answers a close question with.
    nonisolated enum Answer: Sendable, Equatable {
        /// Save to Session: each file's marks are saved first, and the files with nothing left unsaved close.
        case save
        /// Don't Save (Close Anyway when no save is offered): the files close and their unsaved marks are lost.
        case discard
        /// Cancel: nothing closes.
        case cancel
    }

    /// What a close or a quit would lose, or nil when nothing would (the file or the app then closes without asking): the files
    /// whose marks are not saved to their session file, by name, then the rooms still working.
    static func question(dirtyFiles: [String], busyRooms: [String]) -> String? {
        var sentences: [String] = []
        if !dirtyFiles.isEmpty {
            let files = list(dirtyFiles.map { "“\($0)”" })
            let sidecars = dirtyFiles.count == 1 ? "its session file" : "their session files"
            sentences.append("The marks on \(files) are not saved to \(sidecars).")
        }
        if !busyRooms.isEmpty {
            sentences.append("\(list(busyRooms)) \(busyRooms.count == 1 ? "is" : "are") still working.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// “a”; “a” and “b”; “a”, “b” and “c”; past three, the first three and how many more.
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2, 3: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
    }

    /// The close question's title: a save is offered when every file in question can be saved now (`OpenItem.canSave`).
    static func closeTitle(canSave: Bool) -> String {
        canSave ? "Save the marks before closing?" : "Close without saving the marks?"
    }

    /// The close question's text: what would be lost, and what closing without a save does to it.
    static func closeDetail(_ question: String, canSave: Bool) -> String {
        question + (canSave ? " They are lost if you don't save them." : " They cannot be saved now; closing loses them.")
    }

    /// The quit question's title; its text is `question`'s.
    static let quitTitle = "Quit macTEM?"

    /// The close question's buttons, first (Return) to last: Save to Session, Don't Save, Cancel; with no save offered, Cancel
    /// first, so Return never closes, then Close Anyway.
    static func closeButtons(canSave: Bool) -> [Answer] {
        canSave ? [.save, .discard, .cancel] : [.cancel, .discard]
    }

    /// A close question's button title.
    static func title(of answer: Answer, canSave: Bool) -> String {
        switch answer {
        case .save: "Save to Session"
        case .discard: canSave ? "Don't Save" : "Close Anyway"
        case .cancel: "Cancel"
        }
    }
}

/// A close that waits for the user's answer: the files the gesture closes, the one Close Others keeps, and the question.
nonisolated struct CloseRequest: Equatable, Sendable {
    /// Tells two requests for the same files apart: an answer is taken only by the request it was asked for.
    let id = UUID()
    /// Every file the gesture closes, those with nothing unsaved included, in the order given.
    let items: [OpenItem.ID]
    /// Close Others' kept file, selected before the others close (`OpenItems.closeOthers`); nil for a plain close.
    let keeping: OpenItem.ID?
    /// What would be lost (`CloseGuard.question`).
    let question: String
    /// Whether every file with unsaved marks could be saved now, so Save to Session is offered.
    let canSave: Bool
}

extension AppState {
    /// What quitting would lose (`AppDelegate`): every open file with unsaved marks and every room still working; nil when nothing.
    var quitQuestion: String? {
        CloseGuard.question(dirtyFiles: unsavedFiles(openItems.items), busyRooms: busyRooms)
    }

    /// The rooms with work in flight that quitting would end, by title, in the Workspace menu's order.
    var busyRooms: [String] {
        WorkspaceArea.allCases.filter { isWorking($0) }.map(\.title)
    }

    /// ⌘W, the Image menu's Close Image and ⌫ in Open Files: the selected file, through `requestClose`.
    func requestCloseSelected() {
        guard let id = openItems.selectedID else { return }
        requestClose([id])
    }

    /// A row's Close Others: every file but `id`, which is selected first; nothing when `id` is not open.
    func requestCloseOthers(keeping id: OpenItem.ID) {
        guard openItems.item(id) != nil else { return }
        requestClose(openItems.items.map(\.id).filter { $0 != id }, keeping: id)
    }

    /// Closes `ids` now when none of them has marks not saved to its session file; otherwise asks first (`closeRequest`) and the
    /// files stay open until the answer (`answerClose`). Nothing while a question is already up.
    func requestClose(_ ids: [OpenItem.ID], keeping: OpenItem.ID? = nil) {
        guard closeRequest == nil else { return }
        let items = ids.compactMap { openItems.item($0) }
        let unsaved = items.filter { $0.measurements.isDirty }
        guard let question = CloseGuard.question(dirtyFiles: unsavedFiles(unsaved), busyRooms: []) else {
            closeNow(items.map(\.id), keeping: keeping)
            return
        }
        closeRequest = CloseRequest(items: items.map(\.id), keeping: keeping, question: question,
                                    canSave: unsaved.allSatisfy { $0.canSave })
    }

    /// The answer to `request`, the question up: Don't Save closes its files as they are; after Save to Session the files with
    /// nothing left unsaved close, and a file whose save was cancelled or refused stays open; Cancel keeps them all. An answer to
    /// a question no longer up changes nothing.
    func answerClose(_ answer: CloseGuard.Answer, to request: CloseRequest) {
        guard closeRequest == request else { return }
        closeRequest = nil
        switch answer {
        case .discard:
            closeNow(request.items, keeping: request.keeping)
        case .save:
            closeNow(request.items.filter { openItems.item($0)?.measurements.isDirty == false }, keeping: request.keeping)
        case .cancel:
            break
        }
    }

    /// Closes `ids`; Close Others' kept file is selected first, so no other file is selected on the way.
    private func closeNow(_ ids: [OpenItem.ID], keeping: OpenItem.ID?) {
        guard !ids.isEmpty else { return }
        if let keeping { openItems.select(keeping) }
        for id in ids { openItems.close(id) }
    }

    /// The names of the files among `items` whose marks are not saved, as the sidebar titles them (two files of one name are told
    /// apart by their folder).
    private func unsavedFiles(_ items: [OpenItem]) -> [String] {
        let titles = openItems.displayTitles
        return items.filter { $0.measurements.isDirty }.map { titles[$0.id] ?? $0.url.lastPathComponent }
    }

    /// Whether `area` has a run in flight that quitting would end.
    private func isWorking(_ area: WorkspaceArea) -> Bool {
        switch area {
        case .edx: edx.isBusy
        case .eels: eels.isBusy
        case .diffraction: openItems.items.contains(where: { $0.diffraction.isFitting })
        case .patterns: ebsd.isBusy
        case .indexing: indexing.isBusy
        case .maps: maps.isBusy
        case .image, .fft, .results: false
        }
    }
}
