import Foundation

/// One local filesystem change, as the monitor understood it — deliberately
/// coarser than FSEvents' flags, which can tag one entry created and modified
/// and renamed at once. The cleaning stage (§5.3) makes the stream trustworthy.
public struct RawFSEvent: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case created
        case deleted
        case modified
        case moved(to: URL)
    }

    public var kind: Kind
    public var url: URL
    public var isDirectory: Bool

    public init(kind: Kind, url: URL, isDirectory: Bool) {
        self.kind = kind
        self.url = url
        self.isDirectory = isDirectory
    }
}
