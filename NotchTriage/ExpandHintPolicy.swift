/// Pure state for the contextual hint that invites users to expand the panel.
///
/// The policy deliberately knows nothing about `UserDefaults`, SwiftUI, or
/// `AppModel`.  Callers can construct it from persisted primitive values and
/// persist the two exposed values themselves.
struct ExpandHintPolicy: Equatable, Sendable {
    /// Number of valid hovers for which the hint is eligible to be shown.
    static let maxHintImpressions = 3

    /// The number of valid hovers observed so far.
    ///
    /// Values are normalized to `0...maxHintImpressions` when a policy is
    /// created and are saturated at the upper bound when recording hovers.
    private(set) var impressionCount: Int

    /// Whether the user has successfully expanded the panel at least once.
    private(set) var didExpandPanel: Bool

    /// Creates a policy from values suitable for persistence.
    ///
    /// `impressionCount` is an `Int` on purpose: it can be passed directly
    /// from `UserDefaults.integer(forKey:)`. Negative and excessively large
    /// values are normalized to the finite range needed by this policy.
    init(impressionCount: Int = 0, didExpandPanel: Bool = false) {
        self.impressionCount = Self.normalize(impressionCount)
        self.didExpandPanel = didExpandPanel
    }

    /// Alternate spelling for callers that use the shorter state name.
    init(impressionCount: Int, didExpand: Bool) {
        self.init(impressionCount: impressionCount, didExpandPanel: didExpand)
    }

    /// Alternate initializer that makes the persistence boundary explicit.
    init(persistedImpressionCount: Int, didExpandPanel: Bool = false) {
        self.init(
            impressionCount: persistedImpressionCount,
            didExpandPanel: didExpandPanel
        )
    }

    /// Whether the next valid hover is still eligible to show the hint.
    var shouldShowHint: Bool {
        !didExpandPanel && impressionCount < Self.maxHintImpressions
    }

    /// Alias useful when the policy is read as onboarding state.
    var hasExpanded: Bool {
        didExpandPanel
    }

    /// Records one valid hover and returns whether this hover should show the
    /// contextual hint.
    ///
    /// HUD, drag, and closing states are intentionally outside this type; the
    /// caller should invoke this method only for a hover that qualifies. Once
    /// the user has expanded successfully, or the three eligible impressions
    /// have been consumed, this method is a no-op and returns `false`.
    @discardableResult
    mutating func recordValidHover() -> Bool {
        guard !didExpandPanel,
              impressionCount < Self.maxHintImpressions else {
            return false
        }

        impressionCount += 1
        return true
    }

    /// Permanently hides the contextual hint for this policy instance.
    mutating func markExpanded() {
        didExpandPanel = true
    }

    /// Restores the policy to its new-user state.
    mutating func reset() {
        impressionCount = 0
        didExpandPanel = false
    }

    private static func normalize(_ value: Int) -> Int {
        min(max(value, 0), maxHintImpressions)
    }
}
