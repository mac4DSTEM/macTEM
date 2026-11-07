//
//  OxfordOpening.swift
//  Role: an Oxford scan at the app's door, as one `EBSDDataset`: the `.ebsp` pattern file and the `.ctf` map Oxford's software exports
//        next to it with the same name, paired by name whichever of the two is opened (as `EDAXOpening` pairs `.up` and `.ang`). The map
//        is the scan's when its point count is the pattern count; otherwise it is left out with a note. A `.ctf` alone, without its
//        patterns, opens in the Maps room instead (D-SEM-80; D-SEM-25 refused it). The reader's refusals come out in its words.
//

import Foundation

package nonisolated enum OxfordOpening {
    package static let patternExtensions = ["ebsp"]
    package static let mapExtensions = ["ctf"]
    package static let readableExtensions = patternExtensions + mapExtensions

    /// The pattern file an open of `url` reads: `url` itself, or the `.ebsp` next to a `.ctf`; the refusal sentence when there is none.
    package static func patternFile(for url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        if patternExtensions.contains(ext) { return url }
        guard mapExtensions.contains(ext) else {
            throw EBSDReadError(text: "\(url.lastPathComponent) is not an Oxford pattern file (.ebsp) or orientation map (.ctf).")
        }
        guard let patterns = EDAXOpening.companion(of: url, extensions: patternExtensions) else {
            throw EBSDReadError(text: "\(url.lastPathComponent) is an orientation map without its patterns: open the .ebsp of the same name next to it, which reads the map with it.")
        }
        return patterns
    }

    /// Opens the `.ebsp` or `.ctf` at `url` and the companion next to it. Reads the whole `.ctf` (text); run it off the main actor.
    package static func open(url: URL) throws -> EBSDDataset {
        let patternsURL = try patternFile(for: url)
        let mapURL = patternsURL == url ? EDAXOpening.companion(of: url, extensions: mapExtensions) : url
        var dataset: EBSDDataset
        do { dataset = try OxfordBinaryReader.read(url: patternsURL) } catch let refusal as OxfordBinaryReader.Refusal {
            throw EBSDReadError(text: "\(patternsURL.lastPathComponent): \(refusal.reason)")
        } catch { throw EBSDReadError.wrap(error, file: patternsURL) }
        guard let mapURL else { return dataset }
        let file: CTFReader.File
        do { file = try CTFReader.read(path: mapURL.path) } catch let refusal as CTFReader.Refusal {
            guard mapURL != url else { throw EBSDReadError(text: "\(mapURL.lastPathComponent): \(refusal.reason)") }
            // The companion is not the map it should be: the patterns open on their own, with the reason.
            dataset.notes.append("\(mapURL.lastPathComponent) next to it was not read: \(refusal.reason)")
            return dataset
        } catch { throw EBSDReadError.wrap(error, file: mapURL) }
        guard file.pointCount == dataset.patternCount else {
            dataset.notes.append("\(mapURL.lastPathComponent) next to it has \(file.pointCount) points for \(dataset.patternCount) patterns and was left out.")
            return dataset
        }
        dataset.crystalMap = file.map
        return dataset
    }
}
