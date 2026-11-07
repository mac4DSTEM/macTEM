//
//  SEMExportedFile.swift
//  Role: one file a SEM room wrote, as the session keeps it for the Results room and the session report (D-SEM-104): the room, what
//        the file is ("Map PNG"), the dataset it was made from, the room's settings that made it in the room's words, the methods, the
//        picture's bytes when it is a picture, where it was written and when. The rooms make it with the bytes, before the save panel
//        opens (`pending`), and complete it with the place the panel or the journey folder gave (`written(to:at:)`).
//
//        The bytes kept are the bytes written: the report draws the same PNG the person has on disk, never a second render.
//

import Foundation

package nonisolated struct SEMExportedFile: Sendable, Equatable {
    /// The room that wrote it: "Patterns", "Indexing", "Maps".
    package var room: String
    /// What the file is, as the room's Export button names it without the ellipsis: "Map PNG", "Results CSV", "EDAX ANG".
    package var what: String
    /// The file it was made from: "patterns_v2.h5".
    package var source: String
    /// The settings the room had when it wrote it, in the room's words ("Layer", "IPF-Z").
    package var fields: [SEMSessionField]
    package var methods: [SEMMethod]
    /// The PNG's bytes, for a picture; nil for a table or a text file.
    package var png: Data?
    /// Where it was written; nil until the panel says.
    package var file: URL?
    /// When it was written; nil until then.
    package var time: Date?

    package init(room: String, what: String, source: String, fields: [SEMSessionField] = [], methods: [SEMMethod] = [], png: Data? = nil,
                 file: URL? = nil, time: Date? = nil) {
        self.room = room
        self.what = what
        self.source = source
        self.fields = fields
        self.methods = methods
        self.png = png
        self.file = file
        self.time = time
    }

    /// The same export, written to `url` at `time`.
    package func written(to url: URL, at time: Date) -> SEMExportedFile {
        var done = self
        done.file = url
        done.time = time
        return done
    }

    /// An Export button's title as the record names the file: "Map PNG…" is "Map PNG".
    package static func what(_ buttonTitle: String) -> String {
        buttonTitle.hasSuffix("\u{2026}") ? String(buttonTitle.dropLast()) : buttonTitle
    }
}
