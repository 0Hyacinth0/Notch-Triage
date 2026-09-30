import Foundation
import XCTest
@testable import NotchTriage

final class AIUsageTests: XCTestCase {
    func testDecimalRejectsPrefixesNonfiniteAndBooleans() {
        for value in ["12invalid", "NaN", "Infinity", "", "1e9999"] { XCTAssertNil(AIUsageNumber.decimal(value)) }
        XCTAssertNil(AIUsageNumber.decimal(true))
        XCTAssertEqual(AIUsageNumber.decimal("12.50"), Decimal(string: "12.50"))
        XCTAssertEqual(AIUsageNumber.decimal("-1.5"), Decimal(string: "-1.5"))
    }
    func testFullCodexReadClearsMissingAndNullCredits() {
        let previous = CodexCreditsBalance(hasCredits: true, unlimited: false, balance: "125")
        for bucket: [String: Any] in [[:], ["credits": NSNull()]] {
            let full = CodexUsageParser.parseMessage(["result": ["rateLimits": bucket]], previousCredits: previous)
            XCTAssertNil(full?.credits)
            let sparse = CodexUsageParser.parseMessage(["method": "account/rateLimits/updated", "params": ["rateLimits": bucket]], previousCredits: previous)
            XCTAssertEqual(sparse?.credits, previous)
        }
    }
    func testCodexRejectsExtremeDuration() {
        let snapshot = CodexUsageParser.parsePayload(["rateLimits": ["primary": ["usedPercent": 10, "windowDurationMins": 1e100]]])
        XCTAssertTrue(snapshot.limits.isEmpty)
    }
    func testDeepSeekKeepsCurrencyAndBalanceComponents() throws {
        let snapshot = try AIUsageAPI.parse(["balance_infos": [["currency": "CNY", "total_balance": "20.5", "granted_balance": "5", "topped_up_balance": "15.5"]]], provider: .deepseek)
        XCTAssertEqual(snapshot.preferredMetric?.amount, Decimal(string: "20.5"))
        XCTAssertEqual(snapshot.metrics.count, 3)
        XCTAssertEqual(snapshot.preferredMetric?.unit, "CNY")
    }
    func testKimiKeepsNegativeCashAndSeparateVoucher() throws {
        let data: [String: Any] = ["code": 0, "data": ["available_balance": 8, "cash_balance": -2, "voucher_balance": 8]]
        let snapshot = try AIUsageAPI.parse(data, provider: .kimi)
        XCTAssertEqual(snapshot.metrics[1].amount, -2)
        XCTAssertEqual(snapshot.preferredMetric?.amount, 8)
        XCTAssertEqual(try AIUsageAPI.parse(data, provider: .kimiInternational).preferredMetric?.unit, "USD")
    }
    func testOpenRouterAccountBalanceAndKeyBudgetRemainDistinct() throws {
        let account = try AIUsageAPI.parse(["data": ["total_credits": 100, "total_usage": 25]], provider: .openrouter)
        XCTAssertEqual(account.preferredMetric?.amount, 75)
        let key = try AIUsageAPI.parse(["data": ["limit_remaining": 12, "usage": 4]], provider: .openrouter)
        XCTAssertEqual(key.preferredMetric?.title, "此 Key 剩余预算")
        let unlimited = try AIUsageAPI.parse(["data": ["limit_remaining": NSNull(), "usage": 4]], provider: .openrouter)
        XCTAssertEqual(unlimited.preferredMetric?.kind, .spend)
    }
    func testClaudeAccountQuotaIsNotContextUsage() throws {
        let snapshot = try AIUsageAPI.parse(["rate_limits": ["five_hour": ["used_percentage": 20, "resets_at": 1_900_000_000]], "context_window": ["used_percentage": 99], "cost": ["total_cost_usd": 2]], provider: .claude)
        XCTAssertEqual(snapshot.limits.first?.remainingPercent, 80)
        XCTAssertEqual(snapshot.metrics.first?.kind, .estimate)
        XCTAssertThrowsError(try AIUsageAPI.parse(["context_window": ["used_percentage": 99]], provider: .claude))
    }
    func testOrganizationCostUsesCorrectUnitsAndRejectsPartialPages() throws {
        let openai = try AIUsageAPI.parse(["data": [["results": [["amount": ["value": 2.5, "currency": "usd"]]]]], "has_more": false], provider: .openai)
        XCTAssertEqual(openai.preferredMetric?.amount, Decimal(string: "2.5"))
        let anthropic = try AIUsageAPI.parse(["data": [["results": [["amount": "250", "currency": "USD"]]]], "has_more": false], provider: .anthropic)
        XCTAssertEqual(anthropic.preferredMetric?.amount, Decimal(string: "2.5"))
        XCTAssertThrowsError(try AIUsageAPI.parse(["data": [], "has_more": true], provider: .openai))
        XCTAssertThrowsError(try AIUsageAPI.parse(["data": [["results": [["amount": "bad", "currency": "USD"]]]]], provider: .anthropic))
    }
    func testMiniMaxDoesNotGuessCounterSemantics() throws {
        let snapshot = try AIUsageAPI.parse(["base_resp": ["status_code": 0], "model_remains": [["model_name": "test", "current_interval_total_count": 100, "current_interval_usage_count": 20]]], provider: .minimax)
        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertEqual(snapshot.metrics[1].amount, 20)
        let explicit = try AIUsageAPI.parse(["model_remains": [["current_interval_remaining_percent": 35]]], provider: .minimax)
        XCTAssertEqual(explicit.limits.first?.remainingPercent, 35)
    }
    func testCopilotReportsConsumptionWithoutInventingRemainingQuota() throws {
        let snapshot = try AIUsageAPI.parse(["usageItems": [["product": "Copilot", "grossQuantity": 25, "netAmount": 0]]], provider: .copilot)
        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertEqual(snapshot.metrics[0].amount, 25)
        XCTAssertEqual(snapshot.preferredMetric?.kind, .spend)
    }
    func testSnapshotsExpireAndMalformedRepliesNeverBecomeZeroBalance() {
        let date = Date(timeIntervalSince1970: 1000)
        let snapshot = AIUsageSnapshot(updatedAt: date, source: "test")
        XCTAssertFalse(snapshot.isExpired(at: date.addingTimeInterval(180)))
        XCTAssertTrue(snapshot.isExpired(at: date.addingTimeInterval(181)))
        for provider in AIUsageProvider.allCases where !provider.isLocal {
            XCTAssertThrowsError(try AIUsageAPI.parse([:], provider: provider))
        }
    }
    func testEndpointCannotExfiltrateViaUsernameOrKeyConfiguration() throws {
        var connection = AIUsageConnection(provider: .copilot, name: "test")
        connection.context = "user/../../evil"
        XCTAssertThrowsError(try AIUsageAPI.endpoint(connection))
        connection.context = "test-user"
        XCTAssertEqual(try AIUsageAPI.endpoint(connection).host, "api.github.com")
    }
    @MainActor
    func testDiscoveryDeduplicatesAndSkipsNonexecutables() {
        let paths = AIUsageCLI.uniqueExecutableURLs(["/tmp/fake-cli", "/tmp/missing", "/tmp/fake-cli"], isExecutable: { $0 == "/tmp/fake-cli" })
        XCTAssertEqual(paths.map(\.path), ["/tmp/fake-cli"])
    }
    @MainActor
    func testCodexHandshakeFallbackAndAccountChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = root.appendingPathComponent("failed")
        try "#!/bin/sh\nexit 1\n".write(to: failed, atomically: true, encoding: .utf8)
        let client = root.appendingPathComponent("client")
        let script = #"""
#!/usr/bin/python3
import sys,json
if '--version' in sys.argv:
 print('codex-cli fixture');sys.exit()
initialized=False
reads=0
for line in sys.stdin:
 msg=json.loads(line);method=msg.get('method')
 if method=='initialize': print(json.dumps({'id':msg['id'],'result':{}}),flush=True)
 elif method=='initialized': initialized=True
 elif method=='account/rateLimits/read':
  if not initialized: print(json.dumps({'id':msg['id'],'error':{'message':'not initialized'}}),flush=True);continue
  reads+=1
  credits={'hasCredits':True,'unlimited':False,'balance':'125'} if reads==1 else None
  result={'accountId':'fixture-a' if reads==1 else 'fixture-b','rateLimits':{'credits':credits,'primary':{'usedPercent':20,'windowDurationMins':300}}}
  print(json.dumps({'id':msg['id'],'result':result}),flush=True)
  if reads==1: print(json.dumps({'method':'account/updated','params':{}}),flush=True)
"""#
        try script.write(to: client, atomically: true, encoding: .utf8)
        for url in [failed, client] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        let received = expectation(description: "two authoritative snapshots"); received.expectedFulfillmentCount = 2
        var credits: [CodexCreditsBalance?] = [], invalidated = 0
        let service = CodexUsageService(onUsage: { _, value in credits.append(value); received.fulfill() }, onHealth: { _ in }, candidateProvider: { [failed, client] })
        service.onAccountChanged = { invalidated += 1 }
        service.start()
        await fulfillment(of: [received], timeout: 8)
        service.stop()
        XCTAssertEqual(credits.count, 2)
        XCTAssertEqual(credits.first??.credits, 125)
        XCTAssertNil(credits.last!)
        XCTAssertGreaterThan(invalidated, 0)
    }
    @MainActor
    func testCodexHandshakeTimeoutIsReported() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "#!/bin/sh\nexec /bin/sleep 15\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let timedOut = expectation(description: "timeout")
        let service = CodexUsageService(onUsage: { _, _ in XCTFail("no response") }, onHealth: { health in
            if case .failed(let message) = health, message.contains("超时") { timedOut.fulfill() }
        }, requestTimeout: .milliseconds(200), candidateProvider: { [url] })
        service.start()
        await fulfillment(of: [timedOut], timeout: 3)
        service.stop()
    }
    @MainActor
    func testClaudeBridgePreservesOutputSanitizesCacheAndRestoresConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json"), support = root.appendingPathComponent("support")
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "printf original-status", "padding": 2], "theme": "test-theme"]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        let client = root.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '{\"loggedIn\":true,\"email\":\"fixture@example.invalid\",\"authMethod\":\"oauth_token\",\"apiProvider\":\"firstParty\"}'\n".write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        try ClaudeUsageBridge.install(settingsURL: settings, supportDirectory: support, clientURL: client)
        XCTAssertTrue(ClaudeUsageBridge.isEnabled(settingsURL: settings, supportDirectory: support))
        let payload: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": 25]], "cost": ["total_cost_usd": 1], "transcript_path": "/private/not-a-real-transcript", "workspace": ["current_dir": "/private/test"]]
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--claude-statusline", support.appendingPathComponent("claude-runtime.json").path]; process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        let rendered = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(String(data: rendered, encoding: .utf8), "original-status")
        let cached = try Data(contentsOf: support.appendingPathComponent("claude-usage.json"))
        let string = String(decoding: cached, as: UTF8.self)
        XCTAssertFalse(string.contains("transcript")); XCTAssertFalse(string.contains("workspace")); XCTAssertFalse(string.contains("example.invalid"))
        let snapshot = try await ClaudeUsageBridge.read(settingsURL: settings, supportDirectory: support, clientURL: client)
        XCTAssertEqual(snapshot.limits.first?.remainingPercent, 75)
        try ClaudeUsageBridge.uninstall(settingsURL: settings, supportDirectory: support)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! NSDictionary
        XCTAssertEqual(restored, original as NSDictionary)
    }
    @MainActor
    func testClaudeBridgeDoesNotOverwriteSubsequentUserEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json"), support = root.appendingPathComponent("support")
        try ClaudeUsageBridge.install(settingsURL: settings, supportDirectory: support, clientURL: URL(fileURLWithPath: "/usr/bin/true"))
        let edited: [String: Any] = ["statusLine": ["type": "command", "command": "printf user-edited"]]
        try JSONSerialization.data(withJSONObject: edited).write(to: settings)
        try ClaudeUsageBridge.uninstall(settingsURL: settings, supportDirectory: support)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary, edited as NSDictionary)
    }

}
