import Foundation
import Testing

@testable import Auster

/// Moving the Dropbox folder (ux §4): it must refuse where finishing would merge
/// two folders together, and a refusal must leave both sides as they were.
@Suite("Folder mover")
struct FolderMoverTests {

    private func makeSandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auster-mover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seed(_ folder: URL, _ name: String = "a.txt") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test("the folder and its contents arrive at the new location")
    func movesContents() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Dropbox")
        let destination = root.appendingPathComponent("Elsewhere/Dropbox")
        try seed(source)

        try FolderMover.move(from: source, to: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
    }

    /// Two Dropbox folders merged by a move would be indistinguishable from a
    /// mass edit afterwards, so this is the one case that has to fail loudly.
    @Test("a destination that already has files in it is refused")
    func refusesOccupiedDestination() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Dropbox")
        let destination = root.appendingPathComponent("Elsewhere/Dropbox")
        try seed(source)
        try seed(destination, "theirs.txt")

        #expect(throws: FolderMover.MoveError.self) {
            try FolderMover.move(from: source, to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("theirs.txt").path))
    }

    /// An empty folder at the destination is something a file picker creates by
    /// accident; it is not a reason to refuse.
    @Test("an empty destination folder is replaced rather than refused")
    func acceptsEmptyDestination() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Dropbox")
        let destination = root.appendingPathComponent("Elsewhere/Dropbox")
        try seed(source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try FolderMover.move(from: source, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
    }

    @Test("moving a folder onto itself does nothing and does not fail")
    func moveOntoItselfIsANoOp() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Dropbox")
        try seed(source)

        try FolderMover.move(from: source, to: source)

        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path))
    }

    /// Moving a folder into its own subtree would eat it.
    @Test("moving a folder inside itself is refused")
    func refusesMoveIntoOwnSubtree() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Dropbox")
        try seed(source)

        #expect(throws: FolderMover.MoveError.self) {
            try FolderMover.move(from: source, to: source.appendingPathComponent("Inner/Dropbox"))
        }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path))
    }
}
