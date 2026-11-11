//
//  PaneDisplaySection.swift
//  Role: the one Display section of a room with two pictures, the scan map and the pattern (Patterns, Indexing): the room's own display
//        rows first, then a full-width `Map · Pattern` switch and the Display rows of the picture picked (control placement §2 and §5: one
//        Display section, second after Calibration; mac4DSTEM has one Display per pane). Before it these rooms had a Display, a "Map Display"
//        and a "Pattern Display" section, one of them after the processing pipeline.
//

import ShellControls
import ShellInspector
import SwiftUI
import TEMSession

/// Which picture the Display rows set.
enum PaneDisplayTarget: String, CaseIterable, Identifiable, Sendable {
    case map = "Map"
    case pattern = "Pattern"
    var id: String { rawValue }
}

struct PaneDisplaySection<Leading: View>: View {
    /// The map's presentation, or nil when the map draws no scalar values (an IPF or phase map has no colormap): then the rows set the pattern.
    let map: ImagePresentation?
    let pattern: ImagePresentation
    /// The room's prefix for the switch's identifier: "patterns", "indexing".
    let room: String
    /// The colormap pop-ups' identifiers, the rooms' own from before the merge (the journeys find them by name).
    let mapColormapID: String
    let patternColormapID: String
    let leading: Leading
    @State private var target: PaneDisplayTarget = .map

    init(map: ImagePresentation?, pattern: ImagePresentation, room: String, mapColormapID: String, patternColormapID: String,
         @ViewBuilder leading: () -> Leading) {
        self.map = map; self.pattern = pattern; self.room = room
        self.mapColormapID = mapColormapID; self.patternColormapID = patternColormapID; self.leading = leading()
    }

    /// The picture the rows set: the one picked, the pattern when the map has no scalar display.
    private var shown: PaneDisplayTarget { map == nil ? .pattern : target }

    var body: some View {
        InspectorSection("Display") {
            leading
            if map != nil {
                SegmentedPicker(label: "Display of", items: [
                    (PaneDisplayTarget.map, .title("Map", help: "The scan map's colormap, window and gamma")),
                    (PaneDisplayTarget.pattern, .title("Pattern", help: "The pattern's colormap, window and gamma")),
                ], selection: $target)
                .accessibilityIdentifier("\(room).display.target")
            }
            switch shown {
            case .map:
                if let map { ImageRoomDisplayRows(presentation: map, colormapID: mapColormapID) }
            case .pattern:
                ImageRoomDisplayRows(presentation: pattern, colormapID: patternColormapID)
            }
        }
    }
}

extension PaneDisplaySection where Leading == EmptyView {
    /// A room with no display rows of its own (Patterns).
    init(map: ImagePresentation?, pattern: ImagePresentation, room: String, mapColormapID: String, patternColormapID: String) {
        self.init(map: map, pattern: pattern, room: room, mapColormapID: mapColormapID, patternColormapID: patternColormapID) { EmptyView() }
    }
}
