import Foundation

/// Lists a directory's children as URLs the rest of the engine can compare.
///
/// `FileManager.contentsOfDirectory(at:)` cannot be used for this. It returns
/// paths with every symlink resolved (`/private/var/…` where the engine says
/// `/var/…`) and appends a trailing slash to directories, so the URL it hands
/// back for an item is not equal to the URL `PathStore` derives for the same
/// item — and the FS-event ignore filter, the catch-up scan and the index all
/// compare exactly those.
///
/// Names are asked for instead, and the URLs built lexically from the parent the
/// caller already had.
enum DirectoryListing {

    struct Child {
        var url: URL
        var isDirectory: Bool
    }

    /// The directory's children, or an empty list if it cannot be read.
    ///
    /// A symlink is never reported as a directory, whatever it points at: it is
    /// an item in its own right, and following it would walk outside the folder.
    static func children(of directory: URL) -> [Child] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

        return names.map { name in
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes?[.type] as? FileAttributeType
            return Child(url: url, isDirectory: type == .typeDirectory)
        }
    }
}
