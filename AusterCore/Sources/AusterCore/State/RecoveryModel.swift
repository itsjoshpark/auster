import Foundation

/// What Auster offers when sync has stopped, and what each answer does
/// (engine-doc §9, ux §9).
///
/// A pure function from a fatal error to a plan, for the same reason the sync
/// engine keeps its decisions out of its file operations: these paths run on a
/// user's worst day, when the folder has vanished or the token has been revoked,
/// and the thing most likely to turn a bad day into a lost afternoon is a
/// recovery that does its steps in the wrong order. Written down here, the order
/// is a property that can be asserted.
public enum RecoveryModel {

    /// How a fatal error reaches the user.
    public enum Presentation: Sendable, Equatable {

        /// A modal with three answers. Nothing about a missing folder can be
        /// guessed: it may be unmounted, renamed, or genuinely deleted, and the
        /// three cases want opposite things done.
        case folderMissingDialog

        /// The menu carries "Please re-link Auster". Only a browser can fix a
        /// revoked token, so a modal would interrupt without being able to help.
        case relinkPrompt

        /// Get on with it. The index is not data — everything in it can be
        /// recomputed — so asking permission would be asking about nothing.
        case automaticReindex

        /// Nothing to offer but an explanation.
        case message(String)
    }

    /// The three answers to a missing folder.
    public enum FolderMissingChoice: Sendable, Equatable {

        /// The user found it, or is pointing at a copy of it.
        case locate(URL)

        /// Start again with an empty folder at the configured path.
        case recreate

        case quit
    }

    /// One step of a recovery. Deliberately declarative: the app target performs
    /// these, and nothing here touches the filesystem.
    public enum Action: Sendable, Equatable {

        /// Point the engine at a different local folder.
        case adoptFolder(URL)

        /// Make an empty folder at a path.
        case createFolder(URL)

        /// Throw the index away and derive it again from both sides.
        case rebuildIndex

        case quit
    }

    public static func presentation(for error: SyncFatalError) -> Presentation {
        switch error {
        case .dropboxFolderMissing: .folderMissingDialog
        case .notAuthorized: .relinkPrompt
        case .databaseCorrupted: .automaticReindex
        case .unexpected(let message): .message(message)
        }
    }

    /// The steps that carry out one answer, in the order they must happen.
    ///
    /// The folder always comes back before the rebuild, twice over. A rebuild
    /// with no folder would hit the very guard that raised the dialog; and a
    /// rebuild is what makes adopting a folder full of the user's files *safe* —
    /// identical files are skipped on their content hash, and differing ones
    /// become conflicted copies rather than overwrites (decisions D9).
    public static func plan(for choice: FolderMissingChoice, configuredFolder: URL) -> [Action] {
        switch choice {
        case .locate(let url): [.adoptFolder(url), .rebuildIndex]
        case .recreate: [.createFolder(configuredFolder), .rebuildIndex]
        case .quit: [.quit]
        }
    }
}

/// The one-instance rule (ux §9).
///
/// Split from the AppKit scan so the decision can be tested: the trap is that
/// the running-applications list includes the process asking, and an app that
/// mistakes itself for a rival cannot be launched at all.
public enum SingleInstance {

    public enum Decision: Sendable, Equatable {

        /// Nobody else is running; carry on launching.
        case proceed

        /// Hand over to the instance already running, and exit.
        case deferToExisting(pid_t)
    }

    /// - Parameters:
    ///   - otherProcessIdentifiers: every process with Auster's bundle id,
    ///     including this one.
    ///   - current: this process.
    /// - Returns: whether to carry on launching, or which instance to hand over
    ///   to.
    public static func decision(otherProcessIdentifiers: [pid_t], current: pid_t) -> Decision {
        // Lowest pid wins, so two simultaneous launches agree on which of them
        // stands aside rather than both doing so.
        guard let existing = otherProcessIdentifiers.filter({ $0 != current }).min() else {
            return .proceed
        }
        return .deferToExisting(existing)
    }
}
