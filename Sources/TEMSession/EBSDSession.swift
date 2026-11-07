//
//  EBSDSession.swift
//  Role: the one owner of the Patterns room's state (docs/sem/design/ebsd-patterns-room.md): the open EBSD or TKD dataset and where
//        its patterns are read from, the pinned position and the hovered one, the pattern on screen, the navigation map (the mean
//        intensity of every pattern, one pass over the scan) and how the two pictures are drawn (`ImagePresentation` each, so the
//        map and the pattern keep their own contrast). The room's views read it; they hold none of it.
//
//  Nothing here makes a number: the mean map and the virtual images are `VirtualBSEImaging` (TEMCore), the patterns are the readers'. This
//  owner decides WHEN to read: the map in one detached pass that lands only if no newer dataset was bound meanwhile (`generation`),
//  the hovered pattern in a task that is cancelled by the next hover, so a fast sweep over the map reads the pattern the pointer
//  rests on, not every one it passed. Patterns read once stay in a bounded cache by map index.
//

import Foundation
import Observation
import TEMCore

@Observable
package final class EBSDSession {

    /// The open dataset and the way to its patterns (`EBSDPatternAccess`: the file, or memory for the demo).
    package nonisolated struct Document: Sendable {
        package var fileName: String
        /// The file, nil for a dataset answered from memory.
        package var url: URL?
        package var dataset: EBSDDataset
        package var access: any EBSDPatternAccess

        package init(fileName: String, url: URL?, dataset: EBSDDataset, access: any EBSDPatternAccess) {
            self.fileName = fileName; self.url = url; self.dataset = dataset; self.access = access
        }
    }

    // MARK: The dataset

    package private(set) var document: Document?
    package private(set) var isOpening = false
    /// The navigation map's pass: running, and how far (0...1).
    package private(set) var isMapping = false
    package private(set) var mapProgress = 0.0
    /// The mean intensity of every pattern in map order (`EBSDBrowsing.meanIntensityMap`), once the pass has landed.
    package private(set) var meanIntensities: [Float]?
    /// Why the map could not be made (the reader's sentence); nil while it is being made or once it has landed.
    package private(set) var mapFailure: String?

    // MARK: The virtual images (north star F1)

    /// The detector grid the pass cuts the patterns into (`VirtualBSEGrid`); changing it runs the pass again.
    package private(set) var virtualGrid = VirtualBSEGrid(5)
    /// The sum images the pass landed: index 0 the whole detector (the virtual BSE), then `virtualGrid.tiles` in order; each
    /// `scanRows * scanColumns` long. nil until the pass lands.
    package private(set) var virtualImages: [[Float]]?
    /// What the scan map draws.
    package enum MapChoice: Sendable, Hashable {
        /// The mean intensity of every pattern (the navigator).
        case mean
        /// The sum over the whole detector (grid tile 1).
        case bse
        /// One tile of `virtualGrid`.
        case tile(VirtualBSETile)
        /// The colour mix of `mixTiles` (kikuchipy's `get_rgb_image`).
        case mix
    }
    package private(set) var mapChoice = MapChoice.mean
    /// The tiles of the colour mix: red, green, blue; nil until picked.
    package private(set) var mixTiles: [VirtualBSETile?] = [nil, nil, nil]
    /// The colour mix as RGBA bytes for the Metal view, once the three tiles are picked and the pass has landed; its version for the view.
    package private(set) var mixRGBA: [UInt8]?
    package private(set) var mixVersion = 0
    /// The lower pane with every tile (the inspector's "Show the tiles").
    package var showsTiles = false

    // MARK: The position

    /// The pinned position: where the marker stands and what the pattern pane shows while the pointer is off the map.
    package private(set) var pinned = EBSDPosition.origin
    /// The position under the pointer while it hovers the map, else nil.
    package private(set) var hovered: EBSDPosition?
    /// What the pattern pane shows: the hovered position while there is one, else the pinned.
    package var shown: EBSDPosition { hovered ?? pinned }

    // MARK: The pictures

    /// The pattern on screen and the position it is of (the pane keeps the last pattern until the next one arrives: never a blank).
    package private(set) var patternPosition: EBSDPosition?
    package let patternPresentation = ImagePresentation()
    /// How the map is drawn; its canvas is the mean map once it has landed.
    package let mapPresentation = ImagePresentation()

    /// The infobar's line for an event ("Opening…", "Opened…") and the alert for a failure (the window's `AppState` wires them).
    package var onEvent: ((String) -> Void)?
    package var onFailure: ((any Error) -> Void)?

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var mapTask: Task<Void, Never>?
    @ObservationIgnored private var patternTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Patterns read so far, by map index; cleared when it grows past `cacheLimit` and with every new dataset.
    @ObservationIgnored private var cache: [Int: CanvasPixels] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []
    package static let cacheLimit = 512

    package init() {}

    package var fileName: String { document?.fileName ?? "" }
    package var hasDataset: Bool { document != nil }
    package var isBusy: Bool { isOpening || isMapping }
    package var dataset: EBSDDataset? { document?.dataset }

    /// The mean intensity at `position`, once the map has landed.
    package func meanIntensity(at position: EBSDPosition) -> Float? {
        guard let dataset = document?.dataset, let meanIntensities, position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else { return nil }
        return meanIntensities[position.index(columns: dataset.scanColumns)]
    }

    /// The value of the map on screen at `position` with its name ("BSE", "r2 c1"), once the pass has landed; nil for the mean map (the
    /// readout carries the mean on its own) and for the colour mix.
    package func mapValue(at position: EBSDPosition) -> (label: String, value: Float)? {
        guard let dataset = document?.dataset, let image = chosenImage, position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else { return nil }
        let label: String
        switch mapChoice {
        case .bse: label = "BSE"
        case .tile(let tile): label = tile.label
        case .mean, .mix: return nil
        }
        return (label, image[position.index(columns: dataset.scanColumns)])
    }

    /// The sum image `mapChoice` names, once landed.
    package var chosenImage: [Float]? {
        guard let virtualImages else { return nil }
        switch mapChoice {
        case .bse: return virtualImages.first
        case .tile(let tile):
            let k = virtualGrid.index(of: tile) + 1
            return k < virtualImages.count ? virtualImages[k] : nil
        case .mean, .mix: return nil
        }
    }

    /// The tile image of `tile`, once landed.
    package func tileImage(_ tile: VirtualBSETile) -> [Float]? {
        guard let virtualImages else { return nil }
        let k = virtualGrid.index(of: tile) + 1
        return k < virtualImages.count ? virtualImages[k] : nil
    }

    /// Cuts the detector into `grid` and runs the pass again (the tiles and the colour mix are the new grid's).
    package func setVirtualGrid(_ grid: VirtualBSEGrid) {
        guard grid != virtualGrid, let document else { virtualGrid = grid; return }
        virtualGrid = grid
        virtualImages = nil
        mixTiles = [nil, nil, nil]
        mixRGBA = nil
        if case .tile = mapChoice { mapChoice = .mean }
        if mapChoice == .mix { mapChoice = .mean }
        generation += 1
        mapTask?.cancel()
        startMap(document)
    }

    /// Shows `choice` on the scan map (nothing changes until its image has landed; the mix needs its three tiles).
    package func showMap(_ choice: MapChoice) {
        mapChoice = choice
        remakeMap()
    }

    /// Picks `tile` (nil: none) for `channel` of the colour mix (0 red, 1 green, 2 blue); the map shows the mix once all three are picked.
    package func setMixTile(_ tile: VirtualBSETile?, channel: Int) {
        guard (0..<3).contains(channel) else { return }
        mixTiles[channel] = tile
        remakeMix()
        if mixRGBA != nil { mapChoice = .mix }
        remakeMap()
    }

    /// Whether the colour mix can be drawn: three tiles picked and the pass landed.
    package var hasMix: Bool { mixRGBA != nil }

    private func remakeMix() {
        guard let r = mixTiles[0], let g = mixTiles[1], let b = mixTiles[2],
              let red = tileImage(r), let green = tileImage(g), let blue = tileImage(b) else { mixRGBA = nil; return }
        let rgb = VirtualBSEImaging.rgb(red: red, green: green, blue: blue)
        guard !rgb.isEmpty else { mixRGBA = nil; return }
        var rgba = [UInt8](repeating: 255, count: red.count * 4)
        for i in 0..<red.count {
            rgba[4 * i] = rgb[3 * i]; rgba[4 * i + 1] = rgb[3 * i + 1]; rgba[4 * i + 2] = rgb[3 * i + 2]
        }
        mixRGBA = rgba
        mixVersion &+= 1
    }

    /// The map's canvas for `mapChoice`: the mean map, a sum image, or (for the mix, drawn from `mixRGBA`) the mean map's canvas underneath.
    private func remakeMap() {
        guard let dataset = document?.dataset else { return }
        let pixels: [Float]?
        switch mapChoice {
        case .mean, .mix: pixels = meanIntensities
        case .bse, .tile: pixels = chosenImage
        }
        if let pixels { mapPresentation.show(CanvasPixels.make(width: dataset.scanColumns, height: dataset.scanRows, pixels: pixels)) }
    }

    // MARK: Opening

    /// Opens the h5ebsd file at `url` (its first scan) off the main actor, then binds it. The returned task ends when the dataset is bound
    /// and the first pattern is on screen (the map's pass goes on).
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

    @concurrent
    nonisolated private static func read(_ url: URL) async throws -> Document {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let opened = try EBSDOpening.open(url: url)
        return Document(fileName: url.lastPathComponent, url: url, dataset: opened.dataset, access: opened.reader)
    }

    /// Starts the room over on `document`: the pinned position at the origin, the first pattern read, the map's pass started. The returned
    /// task ends when pattern (0, 0) is on screen.
    @discardableResult
    package func bind(_ document: Document) -> Task<Void, Never> {
        generation += 1
        mapTask?.cancel(); patternTask?.cancel()
        self.document = document
        cache = [:]; cacheOrder = []
        pinned = .origin; hovered = nil
        patternPosition = nil; meanIntensities = nil; mapFailure = nil; mapProgress = 0
        virtualImages = nil; mixTiles = [nil, nil, nil]; mixRGBA = nil; mapChoice = .mean
        onEvent?("Opened \(document.fileName) — \(EBSDBrowsing.capsuleDetail(document.dataset)), step \(UnitDisplay.number(document.dataset.stepX)) \(EBSDBrowsing.unitLabel(document.dataset.scanUnit))")
        startMap(document)
        return showPattern(at: .origin)
    }

    /// Ends the open or the map's pass in flight; what has landed stays.
    package func stop() {
        if isOpening { openTask?.cancel(); isOpening = false; onEvent?("Stopped opening") }
        if isMapping { mapTask?.cancel(); isMapping = false; mapFailure = "The map's pass was stopped." }
    }

    /// Closes the dataset: the room goes back to its door.
    package func close() {
        generation += 1
        openTask?.cancel(); mapTask?.cancel(); patternTask?.cancel()
        isOpening = false; isMapping = false
        document = nil; cache = [:]; cacheOrder = []
        meanIntensities = nil; mapFailure = nil; patternPosition = nil; hovered = nil; pinned = .origin
        virtualImages = nil; mixTiles = [nil, nil, nil]; mixRGBA = nil; mapChoice = .mean; showsTiles = false
    }

    // MARK: The map

    /// One pass over the scan in rows (`VirtualBSEImaging.images`): the whole detector's sum and every tile of `virtualGrid`; the mean map
    /// is the whole sum over the pattern's pixels (`EBSDBrowsing.meanIntensityMap`'s number, tested against it).
    private func startMap(_ document: Document) {
        let gen = generation
        isMapping = true
        mapProgress = 0
        mapFailure = nil
        let access = document.access
        let dataset = document.dataset
        let rects = [DetectorRect(top: 0, bottom: dataset.patternRows, left: 0, right: dataset.patternColumns)]
            + virtualGrid.rects(patternRows: dataset.patternRows, patternColumns: dataset.patternColumns)
        mapTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let sums = try VirtualBSEImaging.images(access, rects: rects, progress: { f in
                    Task { @MainActor in self?.landMapProgress(f, generation: gen) }
                }, isCancelled: { Task.isCancelled })
                guard let sums else { return }
                let pixels = Double(max(dataset.patternPixels, 1))
                let mean = sums[0].map { Float($0 / pixels) }
                let images = sums.map { $0.map(Float.init) }
                await self?.landMap(mean, images: images, failure: nil, generation: gen)
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.landMap(nil, images: nil, failure: words, generation: gen)
            }
        }
    }

    private func landMapProgress(_ f: Double, generation gen: Int) {
        guard gen == generation, isMapping else { return }
        mapProgress = f
    }

    private func landMap(_ map: [Float]?, images: [[Float]]?, failure: String?, generation gen: Int) {
        guard gen == generation else { return }
        isMapping = false
        mapProgress = map == nil ? mapProgress : 1
        if let map, let images {
            meanIntensities = map
            virtualImages = images
            remakeMix()
            remakeMap()
        } else if let failure {
            mapFailure = failure
            onEvent?("Error: \(failure)")
        }
    }

    // MARK: The position

    /// The pointer is over map position `position` (nil: it left the map); the pattern pane follows it.
    package func hover(_ position: EBSDPosition?) {
        guard let dataset = document?.dataset else { return }
        let inside = position.flatMap { $0.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) ? $0 : nil }
        guard inside != hovered else { return }
        hovered = inside
        showPattern(at: shown)
    }

    /// Pins `position` (a click on the map, Space on the hovered one, an arrow key): the marker moves and the pattern pane shows it while
    /// the pointer is off the map.
    package func pin(_ position: EBSDPosition) {
        guard let dataset = document?.dataset else { return }
        let clamped = position.clamped(rows: dataset.scanRows, columns: dataset.scanColumns)
        guard clamped != pinned else { return }
        pinned = clamped
        if hovered == nil { showPattern(at: clamped) }
    }

    /// Space: the hovered position becomes the pinned one (nothing when the pointer is off the map).
    package func pinHovered() {
        if let hovered { pin(hovered) }
    }

    /// An arrow key: the pinned position moves `by` positions, held inside the scan.
    package func step(_ direction: EBSDPosition.Direction, by count: Int = 1) {
        guard let dataset = document?.dataset else { return }
        pin(pinned.stepped(direction, by: count, rows: dataset.scanRows, columns: dataset.scanColumns))
    }

    // MARK: The pattern

    /// Shows the pattern at `position`: from the cache at once, else read in a task that the next request cancels. The returned task ends
    /// when the pattern is on screen (at once from the cache).
    @discardableResult
    private func showPattern(at position: EBSDPosition) -> Task<Void, Never> {
        patternTask?.cancel()
        guard let document else { return Task {} }
        let index = position.index(columns: document.dataset.scanColumns)
        if let cached = cache[index] {
            patternPresentation.show(cached)
            patternPosition = position
            return Task {}
        }
        let gen = generation
        let access = document.access
        let task = Task { [weak self] in
            do {
                let canvas = try await Self.readPattern(access, position: position)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.remember(canvas, at: index)
                self.patternPresentation.show(canvas)
                self.patternPosition = position
            } catch {
                guard let self, !Task.isCancelled, gen == self.generation, !(error is CancellationError) else { return }
                self.onFailure?(error)
            }
        }
        patternTask = task
        return task
    }

    @concurrent
    nonisolated private static func readPattern(_ access: any EBSDPatternAccess, position: EBSDPosition) async throws -> CanvasPixels {
        let pattern = try access.pattern(row: position.row, column: position.column)
        try Task.checkCancellation()
        let dataset = access.dataset
        return CanvasPixels.make(width: dataset.patternColumns, height: dataset.patternRows, pixels: EBSDBrowsing.pixels(pattern))
    }

    private func remember(_ canvas: CanvasPixels, at index: Int) {
        if cache.count >= Self.cacheLimit, let oldest = cacheOrder.first {
            cache[oldest] = nil
            cacheOrder.removeFirst()
        }
        cache[index] = canvas
        cacheOrder.append(index)
    }
}
