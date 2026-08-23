import Foundation

/// One local filesystem change, as the monitor understood it.
///
/// Deliberately coarser than FSEvents' flag soup: a single callback entry can
/// arrive tagged created *and* modified *and* renamed at once, and trying to
/// preserve that fidelity buys nothing. The cleaning stage (§5.3) and the
/// rescans it asks for are what make the stream trustworthy, so the monitor's
/// job is to pick the most useful single interpretation and move on.
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
