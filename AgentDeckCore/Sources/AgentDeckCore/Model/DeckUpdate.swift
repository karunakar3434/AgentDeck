import Foundation

/// A coalesced batch of changes pushed to the UI, at most once per frame.
///
/// `changed` carries the full snapshot of every task that changed since the last
/// batch (unchanged tasks are omitted). The UI diffs each snapshot field by field
/// into its long-lived observable models.
public struct DeckUpdate: Sendable {
    public var changed: [TaskSnapshot]
    public var removed: [String]
    /// The source has finished its first scan of existing data.
    public var initialLoadComplete: Bool
    /// Source health when it changed; nil means unchanged since the last update.
    public var health: SourceHealth?

    public init(changed: [TaskSnapshot] = [], removed: [String] = [], initialLoadComplete: Bool = false,
                health: SourceHealth? = nil) {
        self.changed = changed
        self.removed = removed
        self.initialLoadComplete = initialLoadComplete
        self.health = health
    }

    public var isEmpty: Bool { changed.isEmpty && removed.isEmpty }
}
