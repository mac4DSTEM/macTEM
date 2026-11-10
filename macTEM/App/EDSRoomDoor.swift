//
//  EDSRoomDoor.swift
//  Role: INTERIM, delete at MacEMUI <next>. The shared EDS room's own Open button reads the picked file itself (MacEMUI's `EDXRoom`
//        importer calls the session's open), past the app's Open (`AppState.open(urls:)`). Such a file never reached
//        `AppState.edsFiles`, so the rules that read it (`roomsToFollow`, `edsFitBelongs`) did not know the room holds it: the
//        file's image row got no EDS rows in the Results room, and the room did not come back to it with the selection.
//        `ContentView` calls `noteEDSRoomFile` whenever the file the EDS room holds changes; for a file the app's Open routed
//        it finds the file there already. It goes, with its call, when the room's door takes the app's Open (#318).
//

import Foundation

extension AppState {
    /// The EDS room holds the file at `path` (its reader's own statement; nil or empty for a document without a file, the
    /// generated demo): it is one of the files that opened into the EDS room. A file already there is not written again, so
    /// nothing that reads `edsFiles` is drawn again for it.
    func noteEDSRoomFile(path: String?) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard !edsFiles.contains(url) else { return }
        edsFiles.insert(url)
    }
}
