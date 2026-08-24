import Foundation

/// Relocating the local Dropbox folder (ux §4). Conservative on purpose: merging
/// it into somebody else's folder and moving it into itself are both silent
/// until far too late, so both are refused before a single file is touched.
enum FolderMover {

    enum MoveError: LocalizedError, Equatable {

        /// Something is already at the destination. Merging two Dropbox folders
        /// is not a decision this can make on the user's behalf.
        case destinationOccupied(String)

        /// The destination is inside the folder being moved.
        case destinationInsideSource

        case failed(String)

        var errorDescription: String? {
            switch self {
            case .destinationOccupied(let path):
                "There is already a folder with files in it at \(path)."
            case .destinationInsideSource:
                "You cannot move your Dropbox folder inside itself."
            case .failed(let message):
                message
            }
        }
    }

    /// Moves `source` to `destination`, creating the parent directories on the
    /// way. Throws `MoveError` always — a `FileManager` error is wrapped so the
    /// caller has one thing to show in an alert.
    static func move(from source: URL, to destination: URL) throws {
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        guard source != destination else { return }

        guard !isDescendant(destination, of: source) else {
            throw MoveError.destinationInsideSource
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            guard contents.isEmpty else {
                throw MoveError.destinationOccupied(destination.path)
            }
            // An empty folder is what a file picker leaves behind when the user
            // creates one to move into; removing it is not destroying anything.
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                throw MoveError.failed(error.localizedDescription)
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw MoveError.failed(error.localizedDescription)
        }
    }

    /// Component-wise, so a sibling whose name merely starts with the source's
    /// is not mistaken for a child.
    private static func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        let components = url.pathComponents
        let ancestorComponents = ancestor.pathComponents
        guard components.count > ancestorComponents.count else { return false }
        return Array(components.prefix(ancestorComponents.count)) == ancestorComponents
    }
}
