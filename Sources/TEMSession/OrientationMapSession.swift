//
//  OrientationMapSession.swift
//  Role: the one owner of the Maps room's state (docs/sem/design/orientation-maps-room.md, brief P3-04): the orientation map shown (a
//        `CrystalMap` from an `.ang` or `.ctf` opened on its own, or the crystal map of the EBSD dataset the Patterns room holds), which
//        layer the map pane draws (IPF-Z, IPF-X, IPF-Y, Phase or a property) and its picture, the colour keys of the map's phases, and the
//        pinned and hovered scan points. The room's views read it; they hold none of it.
//
//        Nothing here makes a number: the pictures, the hover's words and the unit cell are `OrientationMaps` (TEMCore), the keys
//        `DirectionColorKeyTSL`, the maps the readers'. This owner decides WHEN: a layer's picture is made off the main actor and lands
//        only if no newer map or layer was asked for meanwhile (`generation`); the keys once per Laue group.
//

import Foundation
import Observation
import ShellMetal
import TEMCore

@Observable
package final class OrientationMapSession {

    /// The map shown and where it came from.
    package nonisolated struct Document: Sendable {
        package enum Source: Sendable, Equatable {
            /// An `.ang` or `.ctf` opened on its own: the map without patterns.
            case mapFile
            /// The crystal map of the EBSD dataset open in the Patterns room: the patterns are there for the live pane.
            case patterns
        }

        package var fileName: String
        package var url: URL?
        package var map: CrystalMap
        package var source: Source
        /// "EDAX TSL .ang", "Oxford .ctf", "kikuchipy h5ebsd": who wrote the map, for Info.
        package var format: String

        package init(fileName: String, url: URL?, map: CrystalMap, source: Source, format: String) {
            self.fileName = fileName; self.url = url; self.map = map; self.source = source; self.format = format
        }
    }

    /// One phase's colour key: the TSL key image of its Laue group, with the labelled corners of the sector where they are known.
    package nonisolated struct PhaseKey: Sendable, Identifiable {
        package var phaseID: Int
        package var name: String
        package var pointGroup: String
        package var image: IPFKeyImage
        package var labels: [OrientationMaps.KeyLabel]
        package var id: Int { phaseID }
    }

    // MARK: State

    package private(set) var document: Document?
    package private(set) var isOpening = false
    /// What the map pane draws.
    package private(set) var layer = OrientationMapLayer.ipf(.z)
    /// The picture of `layer` once made; its version for the Metal view.
    package private(set) var raster: OrientationMapRaster?
    /// A colour layer's picture as the Metal view takes it: RGBA bytes, the all-zero scalar plane beside them, and their version.
    package private(set) var rasterRGBA: [UInt8]?
    package private(set) var rasterPlane: [Float] = []
    package private(set) var rasterVersion = 0
    package private(set) var isDrawing = false
    /// Which point every grid cell holds (`OrientationMaps.pointIndexGrid`), −1 where none.
    package private(set) var grid: [Int] = []
    /// A property layer's values as the Metal view draws them through the Display section's colormap and window.
    package let propertyPresentation = ImagePresentation()
    /// The keys of the map's indexed phases with a point group, in phase id order, once made.
    package private(set) var keys: [PhaseKey] = []

    package private(set) var pinned = EBSDPosition.origin
    package private(set) var hovered: EBSDPosition?
    package var shown: EBSDPosition { hovered ?? pinned }

    package var onEvent: ((String) -> Void)?
    package var onFailure: ((any Error) -> Void)?

    @ObservationIgnored private var generation = 0
    /// Bumped by every bind and close: the keys belong to the map, not to the layer.
    @ObservationIgnored private var mapGeneration = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var drawTask: Task<Void, Never>?
    @ObservationIgnored private var keyTask: Task<Void, Never>?
    /// Key images already made, by Laue group name: the same group's key serves every phase and every map.
    @ObservationIgnored private var keyCache: [String: (IPFKeyImage, [OrientationMaps.KeyLabel])] = [:]

    package init() {}

    package var hasMap: Bool { document != nil }
    package var fileName: String { document?.fileName ?? "" }
    package var map: CrystalMap? { document?.map }
    package var isBusy: Bool { isOpening || isDrawing }
    package var gridShape: (rows: Int, columns: Int) { document.map { OrientationMaps.gridShape($0.map) } ?? (0, 0) }
    /// The layers the map offers (`OrientationMaps.layers`).
    package var layers: [OrientationMapLayer] { document.map { OrientationMaps.layers(of: $0.map) } ?? [] }

    // MARK: Opening

    /// Reads the `.ang` or `.ctf` at `url` off the main actor (inside its security scope), then shows it.
    @discardableResult
    package func open(url: URL) -> Task<Void, Never> {
        openTask?.cancel()
        isOpening = true
        onEvent?("Opening \(url.lastPathComponent)…")
        let task = Task { [weak self] in
            do {
                let document = try await Self.read(url)
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                await self.bind(document).value
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                if !(error is CancellationError) { self.onFailure?(error) }
            }
        }
        openTask = task
        return task
    }

    /// The map in an `.ang` (orix's reader port) or a `.ctf`.
    @concurrent
    nonisolated package static func read(_ url: URL) async throws -> Document {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "ang":
            let ang = try ANGReader.read(url: url)
            if ang.header.isHexagonal {
                throw MapReadError(text: "\(url.lastPathComponent) is a hexagonal grid (\(ang.header.grid ?? "HexGrid")); only square-grid EBSD maps are read.")
            }
            return Document(fileName: url.lastPathComponent, url: url, map: ang.map, source: .mapFile, format: Self.angFormat(ang.vendor))
        case "ctf":
            do {
                let ctf = try CTFReader.read(path: url.path)
                return Document(fileName: url.lastPathComponent, url: url, map: ctf.map, source: .mapFile, format: Self.ctfFormat(ctf.vendor))
            } catch let refusal as CTFReader.Refusal {
                throw MapReadError(text: "\(url.lastPathComponent): \(refusal.reason)")
            }
        default:
            throw MapReadError(text: "\(url.lastPathComponent) is not an orientation map (.ang or .ctf).")
        }
    }

    nonisolated static func angFormat(_ vendor: ANGMap.Vendor) -> String {
        switch vendor {
        case .tsl: ".ang (EDAX TSL)"
        case .emsoft: ".ang (EMsoft)"
        case .astar: ".ang (NanoMegas ASTAR)"
        case .orix: ".ang (orix)"
        case .unknown: ".ang"
        }
    }

    nonisolated static func ctfFormat(_ vendor: CTFReader.Vendor) -> String {
        vendor == .orientationTable ? ".ctf (orientation table)" : ".ctf (\(vendor.rawValue))"
    }

    /// The EBSD dataset's crystal map, when it carries one whose points fill its scan: the Maps room shows it with the patterns beside.
    /// nil when the dataset has no map (or one of another size), and the room keeps what it showed.
    package static func patternsDocument(fileName: String, url: URL?, dataset: EBSDDataset) -> Document? {
        guard let map = dataset.crystalMap else { return nil }
        let shape = OrientationMaps.gridShape(map)
        guard shape.rows == dataset.scanRows, shape.columns == dataset.scanColumns else { return nil }
        return Document(fileName: fileName, url: url, map: map, source: .patterns, format: dataset.format.rawValue)
    }

    /// Starts the room over on `document`: IPF-Z, the pinned point at the origin, the picture and the keys made.
    @discardableResult
    package func bind(_ document: Document) -> Task<Void, Never> {
        generation += 1
        mapGeneration += 1
        openTask?.cancel()
        isOpening = false
        self.document = document
        pinned = .origin; hovered = nil
        layer = .ipf(.z)
        raster = nil; rasterRGBA = nil; keys = []
        grid = OrientationMaps.pointIndexGrid(document.map)
        let (rows, columns) = OrientationMaps.gridShape(document.map)
        onEvent?("Opened \(document.fileName) — orientation map \(rows) × \(columns), \(document.map.phasesInData.names.filter { $0 != PhaseList.notIndexedName }.count) phases")
        startKeys(document)
        return draw()
    }

    /// Closes the map: the room goes back to its door.
    package func close() {
        generation += 1
        mapGeneration += 1
        openTask?.cancel(); drawTask?.cancel(); keyTask?.cancel()
        document = nil; isOpening = false; isDrawing = false
        raster = nil; rasterRGBA = nil; grid = []; keys = []
        pinned = .origin; hovered = nil; layer = .ipf(.z)
    }

    /// The Patterns room's dataset went away: a map that came with it goes too; a map opened on its own stays.
    package func patternsClosed() {
        if document?.source == .patterns { close() }
    }

    package func stop() {
        if isOpening { openTask?.cancel(); isOpening = false; onEvent?("Stopped opening") }
    }

    // MARK: The layer

    /// Shows `next`; the returned task ends when its picture has landed.
    @discardableResult
    package func setLayer(_ next: OrientationMapLayer) -> Task<Void, Never> {
        guard next != layer, document != nil else { return Task {} }
        layer = next
        return draw()
    }

    /// Makes the picture of the current layer off the main actor; it lands if nothing newer was asked for.
    @discardableResult
    private func draw() -> Task<Void, Never> {
        guard let document else { return Task {} }
        generation += 1
        let gen = generation
        let layer = self.layer
        let map = document.map
        drawTask?.cancel()
        isDrawing = true
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let raster = OrientationMaps.raster(layer, of: map)
            let canvas = raster.values.map { values in
                CanvasPixels.make(width: raster.columns, height: raster.rows, pixels: values.map(Float.init))
            }
            let rgba = raster.rgba8
            let plane = [Float](repeating: 0, count: raster.rows * raster.columns)
            let version = MetalImageView.contentVersion(of: plane, rgba: rgba, width: raster.columns, height: raster.rows)
            await self?.land(raster, rgba: rgba, plane: plane, version: version, canvas: canvas, generation: gen)
        }
        drawTask = task
        return Task { await task.value }
    }

    private func land(_ raster: OrientationMapRaster, rgba: [UInt8]?, plane: [Float], version: Int, canvas: CanvasPixels?, generation gen: Int) {
        guard gen == generation else { return }
        self.raster = raster
        rasterRGBA = rgba
        rasterPlane = plane
        rasterVersion = version
        if let canvas { propertyPresentation.show(canvas) }
        isDrawing = false
    }

    // MARK: The keys

    private func startKeys(_ document: Document) {
        let gen = mapGeneration
        keyTask?.cancel()
        let cached = keyCache
        let phases = document.map.phasesInData.entries.filter { $0.id != PhaseList.notIndexedID && $0.phase.pointGroup != nil }
        keyTask = Task.detached(priority: .utility) { [weak self] in
            var made: [String: (IPFKeyImage, [OrientationMaps.KeyLabel])] = [:]
            var keys: [PhaseKey] = []
            for (id, phase) in phases {
                guard let group = phase.pointGroup, let laue = group.laue.name else { continue }
                let key = cached[laue] ?? made[laue] ?? OrientationMaps.keyImage(for: group)
                made[laue] = key
                keys.append(PhaseKey(phaseID: id, name: phase.name, pointGroup: phase.pointGroupName ?? laue, image: key.0, labels: key.1))
            }
            await self?.landKeys(keys, made: made, generation: gen)
        }
    }

    private func landKeys(_ keys: [PhaseKey], made: [String: (IPFKeyImage, [OrientationMaps.KeyLabel])], generation gen: Int) {
        keyCache.merge(made) { old, _ in old }
        guard gen == mapGeneration else { return }
        self.keys = keys
    }

    // MARK: Points

    package func hover(_ position: EBSDPosition?) {
        guard let position else { hovered = nil; return }
        let (rows, columns) = gridShape
        hovered = position.isInside(rows: rows, columns: columns) ? position : nil
    }

    package func pin(_ position: EBSDPosition) {
        let (rows, columns) = gridShape
        guard position.isInside(rows: rows, columns: columns) else { return }
        pinned = position
    }

    package func pinHovered() { if let hovered { pinned = hovered } }

    package func step(_ direction: EBSDPosition.Direction, by count: Int = 1) {
        let (rows, columns) = gridShape
        guard rows > 0, columns > 0 else { return }
        pinned = pinned.stepped(direction, by: count, rows: rows, columns: columns)
        hovered = nil
    }

    /// The status line's words for the point at `position` (`OrientationMaps.readout`).
    package func readout(at position: EBSDPosition) -> String? {
        guard let map else { return nil }
        return OrientationMaps.readout(map, grid: grid, row: position.row, column: position.column)
    }

    /// What the orientation pane draws for the point at `position`: its phase, Bunge angles (radians) and rotation, and its colour on the
    /// shown IPF layer (IPF-Z when the layer is not an IPF one); nil for a cell without an indexed point.
    package func orientation(at position: EBSDPosition) -> (phase: CrystalPhase, euler: SIMD3<Double>, rotation: SIMD4<Double>, rgb: SIMD3<Double>, direction: SampleDirection)? {
        guard let map else { return nil }
        let (rows, columns) = gridShape
        guard position.isInside(rows: rows, columns: columns), grid.count == rows * columns else { return nil }
        let i = grid[position.index(columns: columns)]
        guard i >= 0 else { return nil }
        let id = map.allPhaseIDs[i]
        guard id != PhaseList.notIndexedID, let phase = map.phases[id: id] else { return nil }
        var direction = SampleDirection.z
        if case .ipf(let d) = layer { direction = d }
        // The shown IPF picture's colour when it is the one drawn; else the point's IPF-Z colour, made for this one point.
        let rgb: SIMD3<Double>
        if case .ipf = layer, let colours = raster?.rgb, colours.count == rows * columns {
            rgb = colours[position.index(columns: columns)]
        } else {
            rgb = phase.pointGroup.map { IPFColorKeyTSL($0, direction: direction.vector).color(of: [map.rotations[i]])[0] } ?? .zero
        }
        return (phase, map.euler[i], map.rotations[i], rgb, direction)
    }

    /// How many points of the map are not indexed.
    package var notIndexedCount: Int { map?.phaseIDs.filter { $0 == PhaseList.notIndexedID }.count ?? 0 }
}

/// A map file the Maps room could not read, in one sentence.
package nonisolated struct MapReadError: Error, LocalizedError, Equatable {
    package var text: String
    package var errorDescription: String? { text }
    package init(text: String) { self.text = text }
}
