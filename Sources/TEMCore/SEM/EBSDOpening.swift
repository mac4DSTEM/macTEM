//
//  EBSDOpening.swift
//  Role: what the Patterns room opens: the file extensions the Open panel offers, a drop takes and the app declares, and one call that
//        reads a dataset with its pattern reader. The formats are `EBSDH5Reader`'s; the binary vendor formats (EDAX up1/up2, Oxford
//        ebsp, NORDIF) add their extensions here when their readers land.
//

import Foundation

package nonisolated enum EBSDOpening {
    /// Every extension an h5ebsd file comes with: kikuchipy and Bruker write `.h5`, EDAX `.h5` or `.hdf5`, Oxford `.h5oina`; `.h5ebsd` is
    /// the name of the layout and is seen in the wild.
    package static let readableExtensions = ["h5", "hdf5", "h5oina", "h5ebsd"]

    /// The first scan of the file at `url` and the reader for its patterns. Opens the file twice (the header, then the dataset handle it keeps):
    /// run it off the main actor, inside the file's security scope.
    package static func open(url: URL) throws -> (dataset: EBSDDataset, reader: EBSDPatternReader) {
        let dataset = try EBSDH5Reader.read(url: url)
        return (dataset, try EBSDPatternReader(dataset))
    }
}
