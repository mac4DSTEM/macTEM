//
//  ParticleAnalysis.swift
//  Role: the Particles view's owner for one open file (design section 4): the settings, the live mask preview, and the report of
//        the last Show Objects. Never swapped when the item goes cold: it holds no pixels of the image, only labels and numbers.
//
//  Nothing here makes a number. `TEMCore/Particles/ParticleCompute` is ImagoKit's smoothing, labelling and moments with the
//  settings; this owner decides WHEN to ask: the preview and the report each run in a detached task and land only if no newer
//  request was made meanwhile (a generation counter, as the EDX room does). A report is stale when the settings or the image
//  moved on since: `isCurrent`.
//

import Foundation
import Observation
#if canImport(TEMCore)
import TEMCore
#endif

/// The mask the preview tints: the object side of the threshold, one flag per pixel.
package nonisolated struct ParticleMask: Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let mask: [Bool]
    package let version: Int
}

@Observable
package final class ParticleAnalysis {
    package private(set) var settings = ParticleSettings()
    package private(set) var maskPreview: ParticleMask?
    package private(set) var report: ParticleReport?
    package private(set) var isComputing = false
    package private(set) var failure: String?
    /// Whether the objects are outlined on the image (Show Objects).
    package private(set) var showsObjects = false
    /// The row selected in the table; outlined heavier on the image.
    package var selectedLabel: Int32?
    /// Whether the mask is tinted on the image while the settings are edited.
    package private(set) var previewsMask = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var version = 0

    package init() {}

    /// The report is for these settings (an edit since makes it stale; it stays on screen, dimmed, until Show Objects runs again).
    package var isCurrent: Bool { report?.settings == settings }

    package func setSettings(_ edit: (inout ParticleSettings) -> Void) {
        var s = settings
        edit(&s)
        s.thresholdFraction = min(max(s.thresholdFraction, 0), 1)
        s.sigma = max(s.sigma, 0)
        s.minimumArea = max(s.minimumArea, 1)
        guard s != settings else { return }
        settings = s
    }

    package func setPreviewsMask(_ on: Bool) {
        previewsMask = on
        if !on { previewTask?.cancel(); maskPreview = nil }
    }

    package func hideObjects() { showsObjects = false; selectedLabel = nil }

    /// The mask for the current settings, off the main actor; a newer call drops an older one.
    @discardableResult
    package func updatePreview(image: CalibratedImage) -> Task<Void, Never>? {
        guard previewsMask else { return nil }
        previewTask?.cancel()
        generation += 1
        let gen = generation
        let settings = settings, pixels = image.pixels, w = image.width, h = image.height
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            guard let range = ParticleCompute.range(pixels), let cut = try? ParticleCompute.mask(pixels: pixels, width: w, height: h, range: range, settings: settings) else { return }
            if Task.isCancelled { return }
            await self?.landPreview(cut.mask, width: w, height: h, generation: gen)
        }
        previewTask = t
        return t
    }

    private func landPreview(_ mask: [Bool], width: Int, height: Int, generation gen: Int) {
        guard gen == generation, previewsMask else { return }
        version += 1
        maskPreview = ParticleMask(width: width, height: height, mask: mask, version: version)
    }

    /// Show Objects: smooth, threshold, label, measure; the report lands if no newer run was asked.
    @discardableResult
    package func analyse(image: CalibratedImage) -> Task<Void, Never> {
        task?.cancel()
        generation += 1
        let gen = generation
        isComputing = true
        failure = nil
        let settings = settings, pixels = image.pixels, w = image.width, h = image.height
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let interval = Signposts.begin("particles.analyse"); defer { Signposts.end(interval) }
                let report = try ParticleCompute.analyse(pixels: pixels, width: w, height: h, settings: settings)
                if Task.isCancelled { return }
                await self?.land(report, failure: nil, generation: gen)
            } catch {
                if Task.isCancelled { return }
                await self?.land(nil, failure: (error as? LocalizedError)?.errorDescription ?? "\(error)", generation: gen)
            }
        }
        task = t
        return t
    }

    private func land(_ new: ParticleReport?, failure why: String?, generation gen: Int) {
        guard gen == generation else { return }
        isComputing = false
        if let new {
            report = new
            showsObjects = true
            if let sel = selectedLabel, !new.objects.contains(where: { $0.id == sel }) { selectedLabel = nil }
        } else {
            failure = why
        }
    }

    /// The image changed under the item (a re-read with other pixels): the report and the preview belong to the old pixels.
    package func reset() {
        task?.cancel(); previewTask?.cancel(); generation += 1
        report = nil; maskPreview = nil; failure = nil; isComputing = false; showsObjects = false; selectedLabel = nil
    }

    /// Returns when no run is in flight.
    package func settled() async {
        await task?.value
        await previewTask?.value
    }
}
