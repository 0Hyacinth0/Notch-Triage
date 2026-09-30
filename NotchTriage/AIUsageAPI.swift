import Foundation

/// Only fixed, official provider origins receive credentials. Never follow cross-origin redirects.
final class AIUsageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == task.originalRequest?.url?.host else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

enum AIUsageAPI {
    static func read(_ connection: AIUsageConnection, secret: String) async throws -> AIUsageSnapshot {
        let url = try endpoint(connection)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if connection.provider == .anthropic {
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
        if connection.provider == .copilot {
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: AIUsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var (data, response) = try await session.data(for: request)
        if connection.provider == .openrouter, (response as? HTTPURLResponse)?.statusCode == 403 {
            request.url = URL(string: "https://openrouter.ai/api/v1/key")!
            (data, response) = try await session.data(for: request)
        }
        guard let response = response as? HTTPURLResponse else { throw AIUsageError.invalidResponse }
        guard response.statusCode == 200 else { throw AIUsageError.http(response.statusCode) }
        guard data.count <= 2_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageError.invalidResponse
        }
        return try parse(object, provider: connection.provider)
    }

    static func endpoint(_ connection: AIUsageConnection, now: Date = Date()) throws -> URL {
        let start = Int(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        let end = Int(now.timeIntervalSince1970)
        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 86_400))
        let path: String
        switch connection.provider {
        case .deepseek: path = "https://api.deepseek.com/user/balance"
        case .kimi: path = "https://api.moonshot.cn/v1/users/me/balance"
        case .kimiInternational: path = "https://api.moonshot.ai/v1/users/me/balance"
        case .openrouter: path = "https://openrouter.ai/api/v1/credits"
        case .minimax: path = "https://www.minimax.cn/v1/token_plan/remains"
        case .minimaxInternational: path = "https://www.minimax.io/v1/token_plan/remains"
        case .openai: path = "https://api.openai.com/v1/organization/costs?start_time=\(start)&end_time=\(end)&bucket_width=1d&limit=31"
        case .anthropic: path = "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(iso)&bucket_width=1d&limit=31"
        case .copilot:
            let user = connection.context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard user.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil else {
                throw AIUsageError.configuration("请填写有效的 GitHub 用户名")
            }
            path = "https://api.github.com/users/\(user)/settings/billing/premium_request/usage?product=Copilot"
        case .codex, .claude: throw AIUsageError.invalidResponse
        }
        guard let url = URL(string: path) else { throw AIUsageError.invalidResponse }
        return url
    }

    static func parse(_ object: [String: Any], provider: AIUsageProvider, now: Date = Date()) throws -> AIUsageSnapshot {
        var snapshot = AIUsageSnapshot(updatedAt: now, source: provider.title)
        func metric(_ title: String, _ raw: Any?, _ unit: String, _ kind: AIUsageMetric.Kind = .balance) {
            if let amount = AIUsageNumber.decimal(raw) {
                snapshot.metrics.append(.init(title: title, amount: amount, unit: unit, kind: kind))
            }
        }
        switch provider {
        case .deepseek:
            guard let rows = object["balance_infos"] as? [[String: Any]] else { throw AIUsageError.invalidResponse }
            for row in rows {
                guard let currency = row["currency"] as? String, ["USD", "CNY"].contains(currency) else { continue }
                metric("可用余额", row["total_balance"], currency)
                metric("赠金", row["granted_balance"], currency)
                metric("充值余额", row["topped_up_balance"], currency)
            }
        case .kimi, .kimiInternational:
            guard AIUsageNumber.double(object["code"]) == 0, let data = object["data"] as? [String: Any] else { throw AIUsageError.invalidResponse }
            let unit = provider == .kimi ? "CNY" : "USD"
            metric("可用余额", data["available_balance"], unit)
            metric("现金余额", data["cash_balance"], unit)
            metric("代金券", data["voucher_balance"], unit)
        case .openrouter:
            guard let data = object["data"] as? [String: Any] else { throw AIUsageError.invalidResponse }
            if let total = AIUsageNumber.decimal(data["total_credits"]), let used = AIUsageNumber.decimal(data["total_usage"]) {
                snapshot.metrics.append(.init(title: "账户余额", amount: total - used, unit: "USD", kind: .balance))
                metric("累计消费", data["total_usage"], "USD", .spend)
            } else {
                metric("此 Key 剩余预算", data["limit_remaining"], "USD")
                metric("此 Key 累计消费", data["usage"], "USD", .spend)
                snapshot.note = "此 Key 的预算与消费，不代表账户钱包余额；无限预算不会显示为无限余额。"
            }
        case .minimax, .minimaxInternational:
            if let status = object["base_resp"] as? [String: Any], AIUsageNumber.double(status["status_code"]) != 0 { throw AIUsageError.configuration("Token Plan 查询失败，请检查订阅 Key 和套餐状态") }
            guard let rows = object["model_remains"] as? [[String: Any]] else { throw AIUsageError.invalidResponse }
            // Keep explicitly returned counters; do not guess whether `usage_count` means used or remaining.
            for row in rows {
                let name = row["model_name"] as? String ?? "Token Plan"
                for (field, minutes, title) in [("current_interval_remaining_percent", 300, "窗口"), ("current_weekly_remaining_percent", 10_080, "周额度")] {
                    if let percent = AIUsageNumber.double(row[field]), (0...100).contains(percent) {
                        snapshot.limits.append(.init(id: name + field, name: name + " · " + title, usedPercent: 100 - percent, windowMinutes: minutes, resetsAt: nil))
                    }
                }
                metric(name + " · 窗口总量", row["current_interval_total_count"], "count", .count)
                metric(name + " · 平台窗口计数", row["current_interval_usage_count"], "count", .count)
                metric(name + " · 周总量", row["current_weekly_total_count"], "count", .count)
                metric(name + " · 平台周计数", row["current_weekly_usage_count"], "count", .count)
            }
            snapshot.note = "显示平台返回计数；计数口径以控制台为准，未返回剩余百分比时不推算。"
        case .openai, .anthropic:
            guard let days = object["data"] as? [[String: Any]], object["has_more"] as? Bool != true else {
                throw AIUsageError.configuration("消费报告不完整，暂不显示合计")
            }
            var amount = Decimal.zero
            for day in days {
                guard let rows = day["results"] as? [[String: Any]] else { throw AIUsageError.invalidResponse }
                for row in rows {
                    if provider == .openai {
                        guard let entry = row["amount"] as? [String: Any],
                              (entry["currency"] as? String)?.lowercased() == "usd",
                              let value = AIUsageNumber.decimal(entry["value"]) else { throw AIUsageError.invalidResponse }
                        amount += value
                    } else {
                        guard (row["currency"] as? String)?.lowercased() == "usd", let value = AIUsageNumber.decimal(row["amount"]) else { throw AIUsageError.invalidResponse }
                        amount += value / 100 // Anthropic reports decimal USD cents.
                    }
                }
            }
            snapshot.metrics = [.init(title: "最近 30 天消费", amount: amount, unit: "USD", kind: .spend)]
            snapshot.note = "组织 API 账单消费，可能有数据延迟；不是预付余额。"
        case .copilot:
            guard let rows = object["usageItems"] as? [[String: Any]] else { throw AIUsageError.invalidResponse }
            var spent = Decimal.zero, count = Decimal.zero
            for row in rows where (row["product"] as? String)?.lowercased() == "copilot" {
                guard let amount = AIUsageNumber.decimal(row["netAmount"]), let quantity = AIUsageNumber.decimal(row["grossQuantity"]) else { throw AIUsageError.invalidResponse }
                spent += amount; count += quantity
            }
            snapshot.metrics = [.init(title: "本月 premium requests", amount: count, unit: "requests", kind: .count),
                                .init(title: "本月计费消费", amount: spent, unit: "USD", kind: .spend)]
            snapshot.note = "个人购买许可的计费报告；不推算套餐剩余额度。"
        case .claude:
            let limits = object["rate_limits"] as? [String: Any] ?? [:]
            for (key, duration, title) in [("five_hour", 300, "5 小时"), ("seven_day", 10_080, "7 天")] {
                guard let window = limits[key] as? [String: Any], let percent = AIUsageNumber.double(window["used_percentage"]), (0...100).contains(percent) else { continue }
                let reset = AIUsageNumber.double(window["resets_at"]).flatMap { abs($0) < 1e12 ? $0 : nil }.map { Date(timeIntervalSince1970: $0) }
                snapshot.limits.append(.init(id: key, name: title, usedPercent: percent, windowMinutes: duration, resetsAt: reset))
            }
            if let cost = object["cost"] as? [String: Any] { metric("会话估算成本", cost["total_cost_usd"], "USD", .estimate) }
            snapshot.note = "额度来自当前 Claude Code 会话；估算成本不是订阅余额或真实账单。"
        case .codex: throw AIUsageError.invalidResponse
        }
        guard !snapshot.limits.isEmpty || !snapshot.metrics.isEmpty else { throw AIUsageError.noData }
        return snapshot
    }
}
