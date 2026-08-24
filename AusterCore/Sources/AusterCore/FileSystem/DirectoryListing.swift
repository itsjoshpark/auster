import Foundation

/// Lists a directory's children as URLs the rest of the engine can compare.
/// `FileManager.contentsOfDirectory(at:)` resolves symlinks and adds trailing
/// slashes, so its URLs are not equal to the ones `PathStore` derives.
enum DirectoryListing {

    struct Child {
        var url: URL
        var isDirectory: Bool
    }

    /// The directory's children, or an empty list if it cannot be read. A symlink
    /// is never reported as a directory: following it would walk outside.
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
