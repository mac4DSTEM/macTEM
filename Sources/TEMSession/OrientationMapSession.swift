//
//  OrientationMapSession.swift
//  Role: the one owner of the Maps room's state (docs/sem/design/orientation-maps-room.md, brief P3-04): the orientation map shown (a
//        `CrystalMap` from an `.ang`, `.ctf` or map-only `.h5oina` opened on its own, the crystal map of the EBSD dataset the Patterns room holds, or a run
//        of the Indexing room on that dataset, handed over by its `Open in Maps`, D-SEM-99) and the others held for `Source`, which layer
//        the map pane draws (IPF-Z, IPF-X, IPF-Y, Phase or a property) and its picture, the colour keys of the map's phases, and the
//        picked scan point (`pinned`). The room's views read it; they hold none of it.
//
//        P5-04 completes it: `segment()` runs the grain analysis (`MapAnalysis`: grains, boundaries, KAM, GOS, GND, the grain table) off the
//        main actor with the inspector's settings, the slip of each grain under the load direction follows from it, and the texture of one
//        phase (pole figures, IPF density, ODF sections) is made when the bottom pane asks for it.
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
        package enum Source: Sendable, Hashable {
            /// An `.ang`, `.ctf` or map-only `.h5oina` opened on its own: the map without patterns.
            case mapFile
            /// The crystal map of the EBSD dataset open in the Patterns room: the patterns are there for the live pane.
            case patterns
            /// Run `run` of the Indexing room on that dataset (`IndexingSession.runGeneration`), by `method`: the crystal map the room's
            /// .ang and .ctf exports are written from (D-SEM-99). The patterns are there too.
            case indexing(run: Int, method: IndexingMethod)

            /// Whether the map belongs to the Patterns room's dataset: it goes when the dataset goes, and its patterns show beside it.
            package var followsPatterns: Bool {
                switch self {
                case .mapFile: false
                case .patterns, .indexing: true
                }
            }

            /// The room holds one map of each kind, in this order: the map file, the dataset's own map, the Indexing room's run.
            fileprivate var kind: Int {
                switch self {
                case .mapFile: 0
                case .patterns: 1
                case .indexing: 2
                }
            }
        }

        /// What the room's views are rebuilt on: a new map, or the same file's map from another source.
        package struct ID: Hashable, Sendable {
            package var fileName: String
            package var source: Source
        }

        package var fileName: String
        package var url: URL?
        /// The map, fixed once the document is made: the numbers below are worked out from it then.
        package let map: CrystalMap
        package var source: Source
        /// "EDAX TSL .ang", "Oxford .ctf", "kikuchipy h5ebsd": who wrote the map, for Info.
        package var format: String

        /// The map's grid (`OrientationMaps.gridShape`), steps (`dx`, `dy`), points in data, points not indexed and points in data
        /// per phase id, worked out once here (off the main actor where `read` makes the document): the hover, the toolbar and the
        /// inspector read them on every move and redraw, and reducing a large map's coordinates each time stalls the room.
        package let rows: Int
        package let columns: Int
        package let dx: Double
        package let dy: Double
        package let size: Int
        package let notIndexedCount: Int
        package let phaseCounts: [Int: Int]

        package init(fileName: String, url: URL?, map: CrystalMap, source: Source, format: String) {
            self.fileName = fileName; self.url = url; self.map = map; self.source = source; self.format = format
            let shape = OrientationMaps.gridShape(map)
            rows = shape.rows
            columns = shape.columns
            dx = map.dx
            dy = map.dy
            size = map.size
            var counts: [Int: Int] = [:]
            for id in map.phaseIDs { counts[id, default: 0] += 1 }
            phaseCounts = counts
            notIndexedCount = counts[PhaseList.notIndexedID] ?? 0
        }

        package var id: ID { ID(fileName: fileName, source: source) }
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
    /// The maps the room holds, the shown one among them, one of each kind (D-SEM-99): the last map file opened, the crystal map of the
    /// Patterns room's dataset, the Indexing room's run on it handed over by `Open in Maps`. `Source` picks among them; the dataset's
    /// two go with the dataset.
    package private(set) var sources: [Document] = []
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
    /// A property layer's values as the Metal view draws them through the Display section's colormap and window, opening on the layer's
    /// 1st to 99th percentile (a KAM map's few high points otherwise drew the rest black).
    package let propertyPresentation: ImagePresentation = {
        let presentation = ImagePresentation()
        presentation.defaultQuantiles = 0.01...0.99
        return presentation
    }()
    /// The keys of the map's indexed phases with a point group, in phase id order, once made.
    package private(set) var keys: [PhaseKey] = []

    // MARK: Analysis (P5-04)

    /// The grain analysis once Segment has run on this map; nil before.
    package private(set) var analysis: MapAnalysis?
    package private(set) var isSegmenting = false
    /// The settings the next Segment uses.
    package private(set) var analysisSettings = MapAnalysisSettings()
    /// Whether the settings changed since the analysis shown was made.
    package var analysisIsStale: Bool { analysis.map { $0.settings != analysisSettings } ?? false }
    /// The slip-system file of each indexed phase (`MapAnalysis.defaultSlipFile`, or the inspector's pick); a phase without one has none.
    package private(set) var slipFiles: [Int: SlipSystemFile] = [:]
    /// The sample axis of the uniaxial load the Schmid factors are for.
    package private(set) var loadDirection = SampleDirection.x
    /// Every grain's slip under the load, once segmented.
    package private(set) var slip: [GrainSlip] = []
    /// The grain the table and the map's outline show (its number on the grain map).
    package private(set) var selectedGrain: Int?
    /// Every grain selected (⌘-click on the map, several rows of the Grains table): their outlines show on the map and their mean
    /// orientations on the pole figures. `selectedGrain` is the one whose slip the Slip section shows (macTEM#239).
    package private(set) var selectedGrains: Set<Int> = []
    /// The boundary edges the map draws (`MapAnalysis.boundaryEdges`), made once per analysis, and the selected grain's outline.
    package private(set) var grainBoundaryEdges: [(SIMD2<Double>, SIMD2<Double>)] = []
    package private(set) var phaseBoundaryEdges: [(SIMD2<Double>, SIMD2<Double>)] = []
    package private(set) var selectedOutline: [(SIMD2<Double>, SIMD2<Double>)] = []
    /// Whether the map draws the grain and phase boundaries, and the selected grain's slip traces.
    package var showsBoundaries = true
    package var showsSlipTraces = true
    /// The texture of `texturePhaseID` once made.
    package private(set) var texture: MapTexture?
    package private(set) var texturePhaseID: Int?
    package private(set) var isTexturing = false
    /// Whether ⌘. stopped the texture before it landed: the Pole figures and ODF panes say so until it is made again (macTEM#410).
    package private(set) var textureStopped = false
    /// Why the texture of `texturePhaseID` could not be made, the status line's reason, until a texture is asked for again or the map
    /// changes: the panes say it, and Compute Texture stays off, since the same map and phase refuse the same way (macTEM#410).
    package private(set) var textureFailure: String?

    /// The picked point: where the marker stands and what the orientation or pattern pane shows. The pointer over the map picks nothing
    /// (D-SEM-110).
    package private(set) var pinned = EBSDPosition.origin

    package var onEvent: ((String) -> Void)?
    package var onFailure: ((any Error) -> Void)?

    @ObservationIgnored private var generation = 0
    /// Bumped by every bind and close: the keys belong to the map, not to the layer.
    @ObservationIgnored private var mapGeneration = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var drawTask: Task<Void, Never>?
    @ObservationIgnored private var keyTask: Task<Void, Never>?
    @ObservationIgnored private var segmentTask: Task<Void, Never>?
    @ObservationIgnored private var textureTask: Task<Void, Never>?
    /// Bumped by every Segment and stop: an analysis lands only if it is the newest asked for on this map.
    @ObservationIgnored private var segmentGeneration = 0
    /// Key images already made, by Laue group name: the same group's key serves every phase and every map.
    @ObservationIgnored private var keyCache: [String: (IPFKeyImage, [OrientationMaps.KeyLabel])] = [:]

    package init() {}

    package var hasMap: Bool { document != nil }
    package var fileName: String { document?.fileName ?? "" }
    package var map: CrystalMap? { document?.map }
    package var isBusy: Bool { isOpening || isDrawing || isSegmenting || isTexturing }
    /// The map's grid as the document holds it (`Document.rows`, `columns`).
    package var gridShape: (rows: Int, columns: Int) { document.map { (rows: $0.rows, columns: $0.columns) } ?? (0, 0) }
    /// The layers the map offers (`OrientationMaps.layers`).
    package var layers: [OrientationMapLayer] {
        guard let document else { return [] }
        return OrientationMaps.layers(of: document.map) + derivedLayers.map { .derived($0) }
    }

    /// The analysis layers on offer: none before Segment; GND only with a crystal structure DefDAP knows, Schmid only with slip systems.
    package var derivedLayers: [DerivedMapLayer] {
        guard let analysis else { return [] }
        var out: [DerivedMapLayer] = [.grains, .kam, .gos]
        if analysis.gnd != nil { out.append(.gnd) }
        if !slip.isEmpty { out.append(.schmid) }
        return out
    }

    // MARK: Opening

    /// Reads the `.ang`, `.ctf`, map-only `.h5oina` or orix `.h5` at `url` off the main actor (inside its security scope), then shows it.
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

    /// The map in an `.ang` (orix's reader port), a `.ctf`, an Oxford `.h5oina` that holds no patterns, or orix's own `.h5`
    /// (`EBSDH5Reader.readMap`).
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
        case let ext where EBSDOpening.h5Extensions.contains(ext):
            // An Oxford H5OINA without patterns, AZtec's map export (#513), or orix's own HDF5 file (#514): routing sends it here;
            // its refusals come out in its words.
            do {
                let found = try EBSDH5Reader.readMap(url: url)
                let format = switch found.layout {
                case .oxford: Self.h5oinaFormat
                case .orix: Self.orixFormat
                }
                return Document(fileName: url.lastPathComponent, url: url, map: found.map, source: .mapFile, format: format)
            } catch let refusal as EBSDReadError {
                throw MapReadError(text: refusal.text)
            }
        default:
            throw MapReadError(text: "\(url.lastPathComponent) is not an orientation map (.ang, .ctf, .h5oina or orix's .h5).")
        }
    }

    /// The format an H5OINA map is shown with (Info names its Euler angles by it).
    package nonisolated static let h5oinaFormat = ".h5oina (Oxford Instruments)"
    /// The format a map in orix's own HDF5 file is shown with.
    package nonisolated static let orixFormat = ".h5 (orix)"

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
        let document = Document(fileName: fileName, url: url, map: map, source: .patterns, format: dataset.format.rawValue)
        guard document.rows == dataset.scanRows, document.columns == dataset.scanColumns else { return nil }
        return document
    }

    /// Starts the room over on `document` (and holds it as its kind's map): `layer` where the map has it, else IPF-Z; `pinned` where
    /// the map reaches it, else the origin; the picture and the keys made.
    @discardableResult
    package func bind(_ document: Document, layer: OrientationMapLayer = .ipf(.z), pinned: EBSDPosition = .origin) -> Task<Void, Never> {
        generation += 1
        mapGeneration += 1
        openTask?.cancel()
        isOpening = false
        self.document = document
        sources.removeAll { $0.source.kind == document.source.kind }
        sources.append(document)
        sources.sort { $0.source.kind < $1.source.kind }
        let rows = document.rows, columns = document.columns
        self.pinned = pinned.isInside(rows: rows, columns: columns) ? pinned : .origin
        self.layer = OrientationMaps.layers(of: document.map).contains(layer) ? layer : .ipf(.z)
        raster = nil; rasterRGBA = nil; keys = []
        resetAnalysis()
        slipFiles = Self.defaultSlipFiles(document.map)
        grid = OrientationMaps.pointIndexGrid(document.map)
        let phases = document.map.phasesInData.names.filter { $0 != PhaseList.notIndexedName }.count
        onEvent?("Opened \(document.fileName) — orientation map \(columns) × \(rows), \(UnitDisplay.count(phases, "phase", "phases"))")
        startKeys(document)
        return draw()
    }

    /// File > Close Map (⌘W in the Maps room): the map shown goes, and the next map held is shown in its place at the same point and on
    /// the same layer where it has them (`Source`'s order); with none left the room goes back to its door. The other maps stay held.
    @discardableResult
    package func closeShown() -> Task<Void, Never>? {
        guard let shown = document else { close(); return nil }
        sources.removeAll { $0.id == shown.id }
        guard let next = sources.first else { close(); return nil }
        return bind(next, layer: layer, pinned: pinned)
    }

    /// Closes the map and every map held: the room goes back to its door.
    package func close() {
        generation += 1
        mapGeneration += 1
        openTask?.cancel(); drawTask?.cancel(); keyTask?.cancel()
        resetAnalysis()
        slipFiles = [:]
        document = nil; sources = []; isOpening = false; isDrawing = false
        raster = nil; rasterRGBA = nil; grid = []; keys = []
        pinned = .origin; layer = .ipf(.z)
    }

    /// The Patterns room bound another dataset, `map` its crystal map when it carries one (`patternsDocument`), or closed it (`map`
    /// nil): the old dataset's maps go, its own and the Indexing room's run on it. `map` is shown (a map file shown gives way to it and
    /// stays held); without one, a map of the old dataset shown gives way to the map file held, or the room goes back to its door.
    package func patternsChanged(to map: Document?) {
        sources.removeAll { $0.source.followsPatterns }
        if let map {
            bind(map)
        } else if document?.source.followsPatterns == true {
            if let file = sources.first { bind(file) } else { close() }
        }
    }

    /// The Patterns room's dataset went away: `patternsChanged(to: nil)`.
    package func patternsClosed() { patternsChanged(to: nil) }

    /// `Source`: shows the map held as `id`, at the same point and on the same layer where the map has them, so the two results read
    /// side by side in time.
    @discardableResult
    package func showSource(_ id: Document.ID) -> Task<Void, Never>? {
        guard id != document?.id, let held = sources.first(where: { $0.id == id }) else { return nil }
        return bind(held, layer: layer, pinned: pinned)
    }

    /// Whether the map shown is on `dataset`'s scan, point for point: the dataset's own map, or an Indexing run on it (a stopped run's
    /// map holds the first rows of the scan). Its patterns can then show beside it.
    package func isOnScan(of dataset: EBSDDataset) -> Bool {
        guard document?.source.followsPatterns == true else { return false }
        let shape = gridShape
        return shape.rows > 0 && shape.rows <= dataset.scanRows && shape.columns == dataset.scanColumns
    }

    /// ⌘.: ends the open, Segment and the texture in flight; a layer's picture still lands. Segment stops at its next row or grain and
    /// stays busy until its pass has returned (`segmentEnded`), so a second one never runs beside it; what it made is dropped. The
    /// texture's own loops run on to their end, but what they make is dropped; the session remembers it was stopped (`textureStopped`),
    /// and Compute Texture or the texture pane's next appearance asks again.
    package func stop() {
        if isOpening { openTask?.cancel(); isOpening = false; onEvent?("Stopped opening") }
        if isSegmenting, let task = segmentTask, !task.isCancelled {
            segmentGeneration += 1
            task.cancel()
            onEvent?("Stopped segmenting")
        }
        if isTexturing {
            textureTask?.cancel()
            isTexturing = false
            textureStopped = true
            onEvent?("Stopped the texture")
        }
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
        let analysis = self.analysis
        let slip = self.slip
        drawTask?.cancel()
        isDrawing = true
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let raster: OrientationMapRaster
            if case .derived(let derived) = layer, let analysis {
                raster = analysis.raster(derived, slip: slip)
            } else {
                raster = OrientationMaps.raster(layer, of: map)
            }
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

    /// Picks `position` (a click or a drag on the map): nothing outside the map.
    package func pin(_ position: EBSDPosition) {
        let (rows, columns) = gridShape
        guard position.isInside(rows: rows, columns: columns) else { return }
        pinned = position
        followPinnedGrain()
    }

    /// An arrow key: the pick moves `by` points, held inside the map.
    package func step(_ direction: EBSDPosition.Direction, by count: Int = 1) {
        let (rows, columns) = gridShape
        guard rows > 0, columns > 0 else { return }
        pinned = pinned.stepped(direction, by: count, rows: rows, columns: columns)
        followPinnedGrain()
    }

    /// The status line's words for the point at `position` (`OrientationMaps.readout`).
    package func readout(at position: EBSDPosition) -> String? {
        guard let map else { return nil }
        guard let base = OrientationMaps.readout(map, grid: grid, row: position.row, column: position.column, shape: gridShape) else { return nil }
        guard let analysis else { return base }
        return base + Self.analysisReadout(analysis, row: position.row, column: position.column)
    }

    /// The analysis words the status line adds at a grid cell: " · grain 12 · KAM 0.84°" (the KAM where the point has one), the KAM
    /// through `UnitDisplay.fixed` as the room's tables write an angle: printf's digits in `locale`'s decimal mark.
    nonisolated package static func analysisReadout(_ analysis: MapAnalysis, row: Int, column: Int,
                                                    locale: Locale = .autoupdatingCurrent) -> String {
        guard row >= 0, row < analysis.rows, column >= 0, column < analysis.columns else { return "" }
        var out = ""
        if let grain = analysis.grain(atRow: row, column: column) { out += " · grain \(grain)" }
        let kam = analysis.grains.kam[row * analysis.columns + column]
        if kam.isFinite { out += " · KAM " + UnitDisplay.fixed(kam * 180 / Double.pi, places: 2, locale: locale) + "°" }
        return out
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

    // MARK: Segment

    /// Whether Segment can run: a map whose points fill its grid, and no Segment running.
    package var canSegment: Bool {
        guard let document, !isSegmenting else { return false }
        return document.size == document.rows * document.columns
    }

    /// Why Segment is off, in one sentence; nil when it can run.
    package var segmentBlocker: String? {
        guard let document else { return "Open a map first" }
        if isSegmenting { return "Segmenting" }
        if document.size != document.rows * document.columns { return MapAnalysis.Refusal.notAGrid.errorDescription }
        return nil
    }

    /// Changes the settings the next Segment uses (the analysis shown stays until then and reads as stale).
    package func setAnalysisSettings(_ settings: MapAnalysisSettings) {
        analysisSettings = Self.clamped(settings)
    }

    /// The settings held to what the analysis takes: boundary and KAM angles 0.1° to 90°, at least one point per grain.
    nonisolated package static func clamped(_ settings: MapAnalysisSettings) -> MapAnalysisSettings {
        func angle(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, 0.1), 90) : fallback }
        return MapAnalysisSettings(boundaryDegrees: angle(settings.boundaryDegrees, 5), minimumSize: max(1, settings.minimumSize),
                                   kamMaxDegrees: angle(settings.kamMaxDegrees, 5))
    }

    /// Runs the grain analysis with the current settings off the main actor; the returned task ends when it has landed (or was stopped
    /// and its pass has returned).
    @discardableResult
    package func segment() -> Task<Void, Never> {
        guard let document, canSegment else { return Task {} }
        segmentGeneration += 1
        let gen = segmentGeneration
        let settings = analysisSettings
        let map = document.map
        isSegmenting = true
        onEvent?("Segmenting grains…")
        let task = Task { [weak self] in
            do {
                let result = try await MapAnalysis.runAsync(map, settings: settings)
                self?.segmentEnded(generation: gen, result: result, failure: nil)
            } catch {
                self?.segmentEnded(generation: gen, result: nil, failure: error)
            }
        }
        segmentTask = task
        return task
    }

    /// A Segment's pass has returned, done, failed or stopped. Segment is free again only here, so a pass a Stop, a new map or a close
    /// cancelled never runs beside the next one (one pass at a time: `canSegment` waits on `isSegmenting`). Its analysis lands, or its
    /// failure shows, only when it is still the newest asked for on this map.
    private func segmentEnded(generation gen: Int, result: MapAnalysis?, failure: (any Error)?) {
        isSegmenting = false
        guard gen == segmentGeneration else { return }
        if let result {
            landAnalysis(result)
        } else if let failure, !(failure is CancellationError) {
            onFailure?(failure)
        }
    }

    private func landAnalysis(_ result: MapAnalysis) {
        analysis = result
        isSegmenting = false
        let edges = result.boundaryEdges()
        grainBoundaryEdges = edges.grain
        phaseBoundaryEdges = edges.phase
        updateSlip()
        followPinnedGrain()
        onEvent?(Self.segmentedLine(grains: result.table.count, settings: result.settings))
        if case .derived(let d) = layer, !derivedLayers.contains(d) { layer = .derived(.grains) }
        if case .derived = layer { draw() }
    }

    /// Drops the analysis and the texture. A Segment in flight is cancelled and lands nothing; `isSegmenting` stays until its pass has
    /// returned (`segmentEnded`).
    private func resetAnalysis() {
        segmentGeneration += 1
        segmentTask?.cancel(); textureTask?.cancel()
        analysis = nil; slip = []; setSelectedGrain(nil)
        grainBoundaryEdges = []; phaseBoundaryEdges = []
        texture = nil; texturePhaseID = nil; isTexturing = false; textureStopped = false; textureFailure = nil
    }

    /// The Output line a Segment lands with: "Segmented 14 grains (boundaries above 5°, at least 5 points)". The angle in `locale` as the
    /// Grains section's "Made with" row writes it (`MapsRoomFormat.number`, four significant digits): "2.675°", where two decimals by
    /// FormatStyle read "2.68°".
    nonisolated package static func segmentedLine(grains: Int, settings s: MapAnalysisSettings, locale: Locale = .autoupdatingCurrent) -> String {
        "Segmented \(UnitDisplay.count(grains, "grain", "grains")) (boundaries above \(UnitDisplay.number(s.boundaryDegrees, digits: 4, locale: locale))°, "
            + "at least \(UnitDisplay.count(s.minimumSize, "point", "points")))"
    }

    // MARK: Grains

    /// Selects grain `number` (the table's row): its outline shows on the map and the pinned point moves to its point nearest its centroid.
    package func selectGrain(_ number: Int?) {
        guard let number, let analysis, let row = analysis.table.first(where: { $0.id == number }) else { setSelectedGrain(nil); return }
        setSelectedGrain(number)
        let seg = analysis.grains.segmentation.grains[number - 1]
        let c = row.centroid
        let nearest = seg.points.min { a, b in
            let da = SIMD2(Double(a % analysis.columns), Double(a / analysis.columns)) - c
            let db = SIMD2(Double(b % analysis.columns), Double(b / analysis.columns)) - c
            return (da * da).sum() < (db * db).sum()
        }
        if let p = nearest {
            let position = EBSDPosition(row: p / analysis.columns, column: p % analysis.columns)
            if position != pinned { pinned = position }
        }
    }

    private func followPinnedGrain() {
        guard let analysis else { return }
        setSelectedGrain(analysis.grain(atRow: pinned.row, column: pinned.column))
    }

    private func setSelectedGrain(_ number: Int?) {
        setSelection(number.map { [$0] } ?? [], primary: number)
    }

    private func setSelection(_ grains: Set<Int>, primary: Int?) {
        let primary = primary.flatMap { grains.contains($0) ? $0 : nil } ?? grains.min()
        guard grains != selectedGrains || primary != selectedGrain || (!grains.isEmpty && selectedOutline.isEmpty) else { return }
        selectedGrains = grains
        selectedGrain = primary
        selectedOutline = analysis?.outline(of: grains) ?? []
    }

    /// ⌘-click: adds the grain under the point to the selection, or takes it out when it is in it; the point is pinned.
    package func toggleGrain(at position: EBSDPosition) {
        let (rows, columns) = gridShape
        guard position.isInside(rows: rows, columns: columns) else { return }
        pinned = position
        guard let analysis, let number = analysis.grain(atRow: position.row, column: position.column) else { return }
        var grains = selectedGrains
        if grains.contains(number) {
            grains.remove(number)
            setSelection(grains, primary: selectedGrain == number ? nil : selectedGrain)
        } else {
            grains.insert(number)
            setSelection(grains, primary: number)
        }
    }

    /// The Grains table's selection: one row selects and pins its grain (`selectGrain`), several select them all.
    package func selectGrains(_ numbers: Set<Int>) {
        let known = Set(analysis?.table.map(\.id) ?? [])
        let grains = numbers.intersection(known)
        if grains.count <= 1 { selectGrain(grains.first); return }
        setSelection(grains, primary: selectedGrain)
    }

    /// The selected grains' rows, in grain order.
    package var selectedRows: [GrainRow] { analysis?.table.filter { selectedGrains.contains($0.id) } ?? [] }

    /// The selected grain's row and slip.
    package var selectedRow: GrainRow? { selectedGrain.flatMap { g in analysis?.table.first { $0.id == g } } }
    package var selectedSlip: GrainSlip? { selectedGrain.flatMap { g in slip.first { $0.grain == g } } }

    // MARK: Slip

    /// Each indexed phase's default slip-system file.
    nonisolated package static func defaultSlipFiles(_ map: CrystalMap) -> [Int: SlipSystemFile] {
        var out: [Int: SlipSystemFile] = [:]
        for (id, phase) in map.phases.entries where id != PhaseList.notIndexedID {
            if let file = MapAnalysis.defaultSlipFile(for: phase) { out[id] = file }
        }
        return out
    }

    /// Sets (or, with nil, clears) phase `phaseID`'s slip systems.
    package func setSlipFile(_ file: SlipSystemFile?, phaseID: Int) {
        slipFiles[phaseID] = file
        updateSlip()
    }

    /// Sets the load axis of the Schmid factors.
    package func setLoadDirection(_ direction: SampleDirection) {
        guard direction != loadDirection else { return }
        loadDirection = direction
        updateSlip()
    }

    private func updateSlip() {
        guard let analysis, let map else { slip = []; return }
        slip = analysis.slip(load: loadDirection.vector, files: slipFiles, phases: map.phases)
        if case .derived(.schmid) = layer {
            if slip.isEmpty { layer = .derived(.grains) }
            draw()
        }
    }

    // MARK: Texture

    /// The phases the texture tab offers: indexed, with a point group.
    package var texturePhases: [(id: Int, phase: CrystalPhase)] {
        map?.phasesInData.entries.filter { $0.id != PhaseList.notIndexedID && $0.phase.pointGroup != nil } ?? []
    }

    /// Whether Compute Texture can make the texture: a map with a textured phase, no texture shown or being made, and none refused for
    /// the phase picked (`textureFailure`). In practice that is after a stop: a texture pane that appears asks for the texture itself,
    /// after a Source switch too, since the room's panes are rebuilt on `Document.ID`.
    package var canComputeTexture: Bool {
        document != nil && !texturePhases.isEmpty && texture == nil && !isTexturing && textureFailure == nil
    }

    /// Makes the texture of phase `phaseID` (the first textured phase when nil) off the main actor, unless it is the one shown or being made.
    @discardableResult
    package func showTexture(phaseID: Int? = nil) -> Task<Void, Never> {
        guard let document, let id = phaseID ?? texturePhaseID ?? texturePhases.first?.id else { return Task {} }
        if id == texturePhaseID, texture != nil || isTexturing { return Task {} }
        texturePhaseID = id
        texture = nil
        isTexturing = true
        textureStopped = false
        textureFailure = nil
        textureTask?.cancel()
        let map = document.map
        let task = Task { [weak self] in
            var made: MapTexture?
            var failure = ""
            do {
                made = try await MapTexture.computeAsync(map, phaseID: id)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard let self, !Task.isCancelled, self.texturePhaseID == id, self.document?.fileName == document.fileName else { return }
            self.texture = made
            self.isTexturing = false
            // The texture's own sentence (a phase without a point group, orientations that cannot be read) says why.
            if made == nil {
                self.textureFailure = failure
                self.onEvent?("No texture for this phase" + (failure.isEmpty ? "" : ": " + failure))
            }
        }
        textureTask = task
        return task
    }

    /// How many points of the map are not indexed (`Document.notIndexedCount`).
    package var notIndexedCount: Int { document?.notIndexedCount ?? 0 }
}

/// A map file the Maps room could not read, in one sentence.
package nonisolated struct MapReadError: Error, LocalizedError, Equatable {
    package var text: String
    package var errorDescription: String? { text }
    package init(text: String) { self.text = text }
}
