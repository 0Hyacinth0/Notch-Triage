import Foundation

/// The credits snapshot returned by Codex's account/rateLimits API.
///
/// `balance` is kept as the server-provided string because the app-server
/// protocol treats it as display data and allows it to be null. When it is a
/// valid decimal number, `credits` and `estimatedUSD` expose the value without
/// introducing any UI-specific rounding or formatting.
struct CodexCreditsBalance: Equatable {
    /// Whether the account has a credits balance at all.
    let hasCredits: Bool

    /// Whether the account is not constrained by a credits balance.
    let unlimited: Bool

    /// The original app-server balance string. The protocol allows null.
    let balance: String?

    /// The unformatted numeric balance parsed from `balance`.
    let credits: Decimal?

    /// An estimate only: 25 credits are treated as US$1.
    let estimatedUSD: Decimal?

    /// The current conversion published by the Codex credits API.
    static let creditsPerUSD = Decimal(25)

    init(
        hasCredits: Bool,
        unlimited: Bool,
        balance: String?,
        previousBalance: String? = nil
    ) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited

        // Rolling rate-limit updates can omit account metadata or provide a
        // null balance. Keep the last observed balance in either case.
        let resolvedBalance = balance ?? previousBalance
        self.balance = resolvedBalance

        if let resolvedBalance {
            let normalized = resolvedBalance.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let parsed = Decimal(
                string: normalized,
                locale: Locale(identifier: "en_US_POSIX")
            )
            credits = parsed
            estimatedUSD = parsed.map { $0 / Self.creditsPerUSD }
        } else {
            credits = nil
            estimatedUSD = nil
        }
    }

    /// Creates a snapshot while retaining a previous snapshot's nullable
    /// balance when the new payload only updates account flags.
    init(
        hasCredits: Bool,
        unlimited: Bool,
        balance: String?,
        previous: CodexCreditsBalance?
    ) {
        self.init(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: balance,
            previousBalance: previous?.balance
        )
    }
}

/// The data emitted for one account/rateLimits response or update.
struct CodexUsageSnapshot: Equatable {
    let limits: [CodexLimitBucket]
    let credits: CodexCreditsBalance?
}

/// Pure parsing helpers for the JSON dictionaries emitted by codex app-server.
///
/// This deliberately works on already-decoded dictionaries. It never reads
/// credentials, touches the network, or logs payload contents.
enum CodexUsageParser {
    static func parseMessage(
        _ message: [String: Any],
        previousCredits: CodexCreditsBalance? = nil
    ) -> CodexUsageSnapshot? {
        if let result = message["result"] as? [String: Any],
           containsRateLimits(in: result) {
            // A complete read is authoritative when it includes a credits
            // object, so an explicit null balance can clear an old snapshot.
            // (A sparse updated notification uses the preserving path below.)
            return parsePayload(
                result,
                previousCredits: previousCredits,
                preservePreviousBalance: false
            )
        }

        guard message["method"] as? String == "account/rateLimits/updated",
              let params = message["params"] as? [String: Any],
              containsRateLimits(in: params) else {
            return nil
        }
        return parsePayload(
            params,
            previousCredits: previousCredits,
            preservePreviousBalance: true
        )
    }

    static func parsePayload(
        _ payload: [String: Any],
        previousCredits: CodexCreditsBalance? = nil,
        preservePreviousBalance: Bool = true
    ) -> CodexUsageSnapshot {
        let limits = parseLimits(from: payload)
        let credits = parseCredits(
            from: payload,
            previous: previousCredits,
            preservePreviousBalance: preservePreviousBalance
        )
        return CodexUsageSnapshot(limits: limits, credits: credits)
    }

    /// Alias kept intentionally small and discoverable for unit tests and
    /// callers that only have a rate-limit payload (not a JSON-RPC envelope).
    static func parseRateLimits(
        from payload: [String: Any],
        previousCredits: CodexCreditsBalance? = nil,
        preservePreviousBalance: Bool = true
    ) -> CodexUsageSnapshot {
        parsePayload(
            payload,
            previousCredits: previousCredits,
            preservePreviousBalance: preservePreviousBalance
        )
    }

    static func parseJSON(
        _ data: Data,
        previousCredits: CodexCreditsBalance? = nil
    ) -> CodexUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else {
            return nil
        }
        return parseMessage(message, previousCredits: previousCredits)
    }

    private static func containsRateLimits(in payload: [String: Any]) -> Bool {
        payload["rateLimits"] != nil || payload["rateLimitsByLimitId"] != nil
    }

    private static func parseLimits(from payload: [String: Any]) -> [CodexLimitBucket] {
        var buckets: [CodexLimitBucket] = []

        if let byID = payload["rateLimitsByLimitId"] as? [String: Any],
           !byID.isEmpty {
            for (limitID, rawValue) in byID {
                guard let rawBucket = rawValue as? [String: Any] else { continue }
                buckets.append(contentsOf: parseBucket(rawBucket, fallbackID: limitID))
            }
        }

        if buckets.isEmpty,
           let rawBucket = payload["rateLimits"] as? [String: Any] {
            buckets.append(contentsOf: parseBucket(rawBucket, fallbackID: "codex"))
        }

        return buckets
            .filter { $0.windowMinutes > 0 }
            .sorted {
                if $0.windowMinutes == $1.windowMinutes {
                    return $0.id < $1.id
                }
                return $0.windowMinutes < $1.windowMinutes
            }
    }

    private static func parseBucket(
        _ rawBucket: [String: Any],
        fallbackID: String
    ) -> [CodexLimitBucket] {
        let limitID = rawBucket["limitId"] as? String ?? fallbackID
        let displayName = rawBucket["limitName"] as? String ?? "Codex"
        var result: [CodexLimitBucket] = []

        if let primary = rawBucket["primary"] as? [String: Any],
           let bucket = parseWindow(primary, id: "\(limitID)-primary", name: displayName) {
            result.append(bucket)
        }

        if let secondary = rawBucket["secondary"] as? [String: Any],
           let bucket = parseWindow(secondary, id: "\(limitID)-secondary", name: displayName) {
            result.append(bucket)
        }

        return result
    }

    private static func parseWindow(
        _ raw: [String: Any],
        id: String,
        name: String
    ) -> CodexLimitBucket? {
        guard let usedPercent = number(raw["usedPercent"]),
              let windowMinutesDouble = number(raw["windowDurationMins"]) else {
            return nil
        }

        let resetDate = number(raw["resetsAt"]).map {
            Date(timeIntervalSince1970: $0)
        }

        return CodexLimitBucket(
            id: id,
            name: name,
            usedPercent: usedPercent,
            windowMinutes: Int(windowMinutesDouble),
            resetsAt: resetDate
        )
    }

    private static func parseCredits(
        from payload: [String: Any],
        previous: CodexCreditsBalance?,
        preservePreviousBalance: Bool
    ) -> CodexCreditsBalance? {
        // A normal read response has a backward-compatible `rateLimits`
        // snapshot and may also have a `rateLimitsByLimitId` map. Prefer the
        // former when it contains credits, then fall back to the map.
        var candidates: [[String: Any]] = []
        if let rawBucket = payload["rateLimits"] as? [String: Any] {
            candidates.append(rawBucket)
        }
        if let byID = payload["rateLimitsByLimitId"] as? [String: Any] {
            let sortedEntries = byID.sorted { $0.key < $1.key }
            candidates.append(contentsOf: sortedEntries.compactMap { $0.value as? [String: Any] })
        }

        // Supporting a root-level credits object is harmless and makes this
        // parser tolerant of early app-server snapshots used by older builds.
        if let rootCredits = payload["credits"] as? [String: Any],
           let parsed = makeCredits(
               rootCredits,
               previous: preservePreviousBalance ? previous : nil
           ) {
            return parsed
        }

        for candidate in candidates {
            if let rawCredits = candidate["credits"] as? [String: Any],
               let parsed = makeCredits(
                   rawCredits,
                   previous: preservePreviousBalance ? previous : nil
               ) {
                return parsed
            }
        }

        // Missing or null credits are intentionally non-destructive for sparse
        // updates (and for older servers that do not expose credits yet).
        return previous
    }

    private static func makeCredits(
        _ raw: [String: Any],
        previous: CodexCreditsBalance?
    ) -> CodexCreditsBalance? {
        guard let hasCredits = bool(raw["hasCredits"]),
              let unlimited = bool(raw["unlimited"]) else {
            return nil
        }

        return CodexCreditsBalance(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: raw["balance"] as? String,
            previous: previous
        )
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let integer = value as? Int {
            return Double(integer)
        }
        return nil
    }
}
