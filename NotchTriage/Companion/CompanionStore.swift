import AppKit
import Combine

@MainActor final class CompanionStore: ObservableObject {
    @Published private(set) var archive = CompanionArchive()
    @Published private(set) var notice: String?
    @Published private(set) var lastResult: String?
    @Published private(set) var action = ""
    @Published private(set) var actionRevision = 0
    @Published private(set) var nestGuideRequested = false
    private(set) var previousForm: Int?
    let nestFeedback = CompanionNestFeedback()
    var isVisible = false
    var settingsOpener: (() -> Void)?
    var desktopDragHandler: ((NSPoint?) -> Void)?
    func openSettings(_ section: String = "我的伙伴") {
        UserDefaults.standard.set(section, forKey: "NotchTriage.Companion.selectedSection")
        settingsOpener?()
    }
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var lastWrite = 0.0
    private var writable = true
    private let url: URL
    var pet: CompanionPet? { archive.pets.first { $0.id == archive.selected } }
    var session: CompanionSession? { archive.session }
    var preferences: CompanionPreferences { archive.preferences }

    func isGameUnlocked(_ game: CompanionGame) -> Bool {
        switch game {
        case .snake:
            return true
        case .flight:
            return archive.flightUnlocked || archive.pets.contains { $0.stage >= 1 }
        }
    }

    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchTriage/Companion/archive.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { archive = try Self.read(url) } catch {
                if let backup = try? Self.read(url.appendingPathExtension("backup")) {
                    archive = backup
                    notice = "已从上次备份恢复伙伴存档。"
                } else {
                    writable = false
                    notice = "伙伴存档无法读取，原文件已保留。请导入有效存档或在桌面与数据中重置。"
                }
            }
        }
        let hours = max(0, Date().timeIntervalSince(archive.lastSaved)) / 3600
        for i in archive.pets.indices {
            archive.pets[i].energy = min(100, archive.pets[i].energy + min(40, hours * 10))
        }
        archive.session?.pause()
        if let s = session, s.finished && !s.settled { settle() }
        if preferences.inNest { showFirstNestGuide() }
    }
    func start() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        session?.pause()
        save()
    }
    func editPreferences(_ edit: (inout CompanionPreferences) -> Void) {
        let oldScreen = preferences.screenID
        edit(&archive.preferences)
        if oldScreen != preferences.screenID {
            session?.pause()
            signal("display")
        }
        if !preferences.enabled { session?.pause() }
        save()
    }
    func enable(_ enabled: Bool) {
        guard writable else { return }
        archive.preferences.enabled = enabled
        if enabled && archive.careAchievements.insert("C00").inserted {
            archive.eggs += 1
            archive.eggSources.append("初次相遇")
        }
        if !enabled { session?.pause() }
        save()
    }
    func hatch() {
        guard preferences.enabled, archive.eggs > 0, writable else { return }
        let owned = Set(archive.pets.map(\.family))
        var family = Int.random(in: 0..<3)
        if archive.duplicateStreak >= 2, owned.count < 3 {
            family = Array(Set(0..<3).subtracting(owned)).randomElement()!
        }
        archive.duplicateStreak = owned.contains(family) ? archive.duplicateStreak + 1 : 0
        let p = CompanionPet(family: family, name: CompanionCatalog.families[family])
        archive.pets.append(p)
        archive.eggs -= 1
        if !archive.eggSources.isEmpty { archive.eggSources.removeFirst() }
        if archive.selected == nil {
            archive.selected = p.id
            archive.preferences.inNest = false
        }
        signal("hatch")
        evaluateCare()
        save()
    }
    func select(_ id: UUID) {
        guard session == nil, archive.pets.contains(where: { $0.id == id }) else {
            notice = "请先继续原局，或结束并结算后更换精灵。"
            return
        }
        mutatePet { p in for i in p.wasteObjects.indices { p.wasteObjects[i].inNest = true } }
        archive.selected = id
        archive.preferences.resting = false
        archive.preferences.inNest = false
        signal("out")
        save()
    }
    func rename(_ name: String) {
        mutatePet { $0.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) }
        save()
    }
    func nest() {
        session?.pause()
        archive.preferences.inNest = true
        mutatePet { p in for i in p.wasteObjects.indices { p.wasteObjects[i].inNest = true } }
        signal("nest")
        save()
    }
    func emerge() {
        if nestGuideRequested { dismissNestGuide() }
        archive.preferences.inNest = false
        signal("out")
        save()
    }
    func showFirstNestGuide() {
        guard !UserDefaults.standard.bool(forKey: "NotchTriage.Companion.nestGuideSeen.v1") else { return }
        nestGuideRequested = true
    }
    func requestNestGuide() { nestGuideRequested = true }
    func dismissNestGuide() {
        nestGuideRequested = false
        UserDefaults.standard.set(true, forKey: "NotchTriage.Companion.nestGuideSeen.v1")
    }
    func rest() {
        session?.pause()
        archive.preferences.resting.toggle()
        signal("rest")
        save()
    }
    func signal(_ name: String) {
        action = name
        actionRevision += 1
    }
    func clearNotice() { notice = nil }
    private func mutatePet(_ edit: (inout CompanionPet) -> Void) {
        guard let i = archive.pets.firstIndex(where: { $0.id == archive.selected }) else { return }
        var p = archive.pets[i]
        edit(&p)
        archive.pets[i] = p
    }
    private var today: String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func growth(_ p: inout CompanionPet, key: String, amount: Int, cap: Int, care: Bool = false) {
        let day = today
        let event = day + ":" + key
        guard p.dailyCounts[event, default: 0] < cap else { return }
        p.dailyCounts[event, default: 0] += 1
        let grant = min(amount, max(0, 35 - p.dailyGrowth[day, default: 0]))
        p.dailyGrowth[day, default: 0] += grant
        p.growth = min(200, p.growth + grant)
        if care { p.dailyCounts[day + ":care"] = 1 }
        if p.dailyGrowth[day, default: 0] >= 10 && p.dailyCounts[day + ":care", default: 0] > 0 {
            p.days.insert(day)
        }
        if p.stage >= 1 {
            p.unlockedForms.insert(1)
            if p.form == 0 { p.form = 1 }
        }
    }
    func care(_ kind: String) {
        guard preferences.enabled, pet != nil, writable else { return }
        session?.pause()
        var accepted = false
        mutatePet { p in
            let cooldown = kind == "meal" ? 15.0 : kind == "snack" ? 10 : kind == "bath" ? 15 : 5
            let last = p.cooldowns[kind] ?? -1000
            guard kind == "clean" || p.activeMinutes - last >= cooldown else { return }
            if (kind == "meal" || kind == "snack") && p.satiety >= 90 { return }
            if kind == "clean" && p.waste == 0 { return }
            if kind == "bath" && p.cleanliness >= 100 { return }
            accepted = true
            p.cooldowns[kind] = p.activeMinutes
            switch kind {
            case "pet":
                p.mood = min(100, p.mood + 4)
                p.bond = min(1000, p.bond + 2)
                growth(&p, key: "pet", amount: 2, cap: 2, care: true)
            case "meal":
                p.satiety = min(100, p.satiety + 25)
                p.bond = min(1000, p.bond + 3)
                p.digestion += 1
                p.meals += 1
                growth(&p, key: "meal", amount: 4, cap: 2, care: true)
            case "snack":
                p.satiety = min(100, p.satiety + 10)
                p.mood = min(100, p.mood + 3)
            case "clean":
                let n = p.waste
                p.wasteObjects.removeAll()
                p.cleanliness = min(100, p.cleanliness + Double(n * 15))
                p.bond = min(1000, p.bond + n * 2)
                p.cleans += n
                for _ in 0..<n { growth(&p, key: "clean", amount: 3, cap: 2, care: true) }
            case "bath":
                p.cleanliness = 100
                p.mood = min(100, p.mood + 5)
                p.cleans += 1
                growth(&p, key: "clean", amount: 3, cap: 2, care: true)
            default: accepted = false
            }
            if accepted { growth(&p, key: "first", amount: 8, cap: 1, care: true) }
        }
        signal(kind)
        notice =
            accepted
            ? nil : (kind == "meal" || kind == "snack" ? "它已经吃饱，或刚刚吃过。陪它走走再来吧。" : "它回应了你；这次没有额外照料奖励。")
        evaluateCare()
        save()
    }
    func cleanWaste(_ id: UUID) {
        guard preferences.enabled else { return }
        var cleaned = false
        mutatePet { p in
            guard let i = p.wasteObjects.firstIndex(where: { $0.id == id }) else { return }
            p.wasteObjects.remove(at: i)
            p.cleanliness = min(100, p.cleanliness + 15)
            p.bond = min(1000, p.bond + 2)
            p.cleans += 1
            growth(&p, key: "clean", amount: 3, cap: 2, care: true)
            growth(&p, key: "first", amount: 8, cap: 1, care: true)
            cleaned = true
        }
        if cleaned {
            signal("clean")
            evaluateCare()
            save()
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(2, max(0, now - lastTick))
        lastTick = now
        guard preferences.enabled else { return }
        let playing = session != nil && session?.paused == false
        if isVisible {
            mutatePet { p in
                let minutes = dt / 60
                if !playing && p.energy < 20 { p.autoResting = true }
                if p.energy >= 60 { p.autoResting = false }
                if preferences.inNest || preferences.resting || p.autoResting && !playing {
                    p.energy = min(100, p.energy + minutes * (preferences.inNest ? 0.5 : 1))
                    if preferences.resting { p.restMinutes += minutes }
                } else {
                    p.energy = max(0, p.energy - minutes / (playing ? 2 : 10))
                }
                if !preferences.inNest && !(session?.paused == true) {
                    let before = Int(p.activeMinutes / 10)
                    p.activeMinutes += minutes
                    p.satiety = max(0, p.satiety - minutes / 15)
                    p.cleanliness = max(0, p.cleanliness - minutes / 30)
                    if p.satiety < 20 || p.cleanliness < 30 { p.mood = max(35, p.mood - minutes / 30) }
                    if Int(p.activeMinutes / 10) > before { growth(&p, key: "time", amount: 1, cap: 12) }
                }
                if !playing && p.digestion >= 2 && p.activeMinutes - p.lastPoop >= 45 && p.waste < 2 {
                    p.wasteObjects.append(
                        .init(
                            x: min(0.97, preferences.positionX + Double(p.waste) * 0.03),
                            y: preferences.positionY, inNest: preferences.inNest))
                    p.digestion -= 2
                    p.lastPoop = p.activeMinutes
                    p.cleanliness = max(0, p.cleanliness - 10)
                }
            }
            evaluateCare()
        }
        if now - lastWrite > 30 {
            save()
            lastWrite = now
        }
    }
    func progress(_ game: CompanionGame) -> CompanionProgress {
        game == .snake ? archive.snake : archive.flight
    }
    private func setProgress(_ p: CompanionProgress, game: CompanionGame) {
        if game == .snake { archive.snake = p } else { archive.flight = p }
    }
    func equip(_ number: Int, game: CompanionGame) {
        guard session == nil else {
            notice = "本局装备已经固定，请结算后更换。"
            return
        }
        var p = progress(game)
        guard p.owned.contains(number) else { return }
        if let i = p.equipment.firstIndex(of: number) {
            p.equipment.remove(at: i)
        } else {
            guard p.equipment.count < 2 else {
                notice = "两个装备位已满，请先取下一件。"
                return
            }
            if let other = CompanionCatalog.relics(game)[number - 1].conflicts, p.equipment.contains(other) {
                notice = "这两件遗物互斥，请先取下另一件。"
                return
            }
            p.equipment.append(number)
        }
        setProgress(p, game: game)
        save()
    }
    func startGame(_ game: CompanionGame, manual: Bool = false) {
        guard preferences.enabled, let pet else {
            notice = "请先开启伙伴并孵化一枚蛋。"
            return
        }
        guard session == nil else {
            notice = "已有一局保存中，请继续或先结束并结算。"
            return
        }
        guard isGameUnlocked(game) else {
            notice = "任一精灵进入成长期后解锁星灯航行。"
            return
        }
        archive.preferences.inNest = false
        archive.preferences.resting = false
        archive.session = CompanionSession(
            pet: pet.id, game: game, progress: progress(game), family: pet.family, form: pet.form)
        session?.manual = manual
        lastResult = nil
        save()
    }
    func pause() {
        session?.pause()
        objectWillChange.send()
        save()
    }
    func resume() {
        guard preferences.enabled else { return }
        archive.preferences.resting = false
        guard !preferences.inNest else {
            emerge()
            return
        }
        session?.resume()
        objectWillChange.send()
    }
    func handoff() {
        if let s = session {
            s.handoff(!s.manual)
            s.chooseAutomatically()
            if preferences.inNest { s.pause() }
            objectWillChange.send()
        }
    }
    func choose(_ item: Int, replacing: Int? = nil) {
        guard preferences.enabled else { return }
        session?.choose(item, replacing: replacing)
        if preferences.inNest { session?.pause() }
        objectWillChange.send()
        save()
    }
    func finish() {
        session?.end("主动结束")
        settle()
    }
    func refreshGameUI() {
        objectWillChange.send()
        if session?.finished == true { settle() }
    }
    private func settle() {
        guard let s = session, !s.settled else { return }
        s.settled = true
        var p = progress(s.game)
        for i in 0..<4 { p.xp[i] = min(1800, p.xp[i] + s.xp[i]) }
        for (key, value) in s.counts { p.totals[key, default: 0] += value }
        p.best = max(p.best, s.score)
        var rewards: [String] = []
        let snake = s.game == .snake
        let food = s.counts["food", default: 0]
        let conditions =
            snake
            ? [
                food >= 5, p.totals["food", default: 0] >= 20, food >= 15, p.totals["food", default: 0] >= 50,
                p.totals["turn", default: 0] >= 100, p.level(0) >= 3, p.totals["food", default: 0] >= 100,
                food >= 30,
            ]
            : [
                p.totals["kill", default: 0] >= 10, p.totals["wave", default: 0] >= 3,
                p.totals["wave", default: 0] >= 6, p.totals["armor", default: 0] >= 5,
                p.totals["boss", default: 0] >= 1, p.totals["supply", default: 0] >= 10,
                p.totals["wave", default: 0] >= 12, p.totals["boss", default: 0] >= 3,
            ]
        for i in 0..<8 where conditions[i] {
            if p.achievements.insert("\(s.game.prefix)C0\(i + 1)").inserted {
                p.owned.insert(i + 1)
                rewards.append(CompanionCatalog.relics(s.game)[i].name)
            }
        }
        func reward(_ index: Int, when condition: Bool, egg: Bool, cosmetic: Int? = nil) {
            let key = "\(s.game.prefix)C\(String(format: "%02d", index))"
            if condition && p.achievements.insert(key).inserted {
                if egg {
                    archive.eggs += 1
                    archive.eggSources.append("\(s.game.title) · \(key)")
                    rewards.append("精灵蛋")
                }
                if let cosmetic {
                    archive.cosmetics.insert(cosmetic)
                    rewards.append("新外观")
                }
            }
        }
        reward(9, when: s.time >= 180, egg: true)
        reward(
            10, when: snake ? p.totals["food", default: 0] >= 200 : p.totals["wave", default: 0] >= 24,
            egg: true)
        reward(
            11, when: snake ? food >= 50 : s.counts["boss3", default: 0] > 0, egg: false,
            cosmetic: snake ? 5 : 7)
        reward(12, when: p.level(snake ? 0 : 1) >= 5, egg: false, cosmetic: snake ? 6 : 8)
        let tiers = p.totals[snake ? "food" : "boss", default: 0] / (snake ? 1000 : 30)
        let earned = p.totals["eggTiers", default: 0]
        if tiers > earned {
            archive.eggs += tiers - earned
            archive.eggSources += Array(repeating: "\(s.game.title) · 持续陪练", count: tiers - earned)
            p.totals["eggTiers"] = tiers
            rewards.append("里程碑精灵蛋 ×\(tiers - earned)")
        }
        setProgress(p, game: s.game)
        if let i = archive.pets.firstIndex(where: { $0.id == s.petID }), !s.counts.isEmpty {
            var pet = archive.pets[i]
            pet.bond = min(1000, pet.bond + 2)
            pet.mood = min(100, pet.mood + 3)
            growth(&pet, key: "game", amount: 2, cap: 2)
            archive.pets[i] = pet
        }
        let gains = s.xp.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(2)
            .map { "\(CompanionCatalog.skills.filter { $0.game == s.game }[$0.offset].name) +\($0.element)" }
            .joined(separator: " · ")
        lastResult =
            "\(s.result) · \(s.score) 分\n\(gains)"
            + (rewards.isEmpty ? "" : "\n解锁：" + rewards.joined(separator: "、"))
        archive.session = nil
        signal("result")
        evaluateCare()
        save()
    }
    private func evaluateCare() {
        archive.snakeUnlocked = true
        if archive.pets.contains(where: { $0.stage >= 1 }) { archive.flightUnlocked = true }
        for i in archive.pets.indices where archive.pets[i].stage == 2 {
            let p = archive.pets[i]
            let basic =
                p.bond >= 20
                && (p.family == 0 ? p.meals >= 3 : p.family == 1 ? p.restMinutes >= 20 : p.cleans >= 2)
            let pair = [(0, 2), (1, 1), (2, 3)][p.family]
            let advanced =
                p.bond >= 50 && (archive.snake.level(pair.0) >= 3 || archive.flight.level(pair.1) >= 3)
            if basic { archive.pets[i].unlockedForms.insert(2) }
            if advanced { archive.pets[i].unlockedForms.insert(3) }
        }
        let conditions = [
            true, archive.pets.contains { $0.meals > 0 }, archive.pets.reduce(0) { $0 + $1.cleans } >= 5,
            archive.flightUnlocked, archive.pets.contains { $0.bond >= 100 },
            archive.pets.reduce(0) { $0 + $1.unlockedForms.filter { $0 >= 2 }.count } >= 2,
            Set(archive.pets.map(\.family)).count == 3, archive.pets.filter { $0.stage == 2 }.count >= 2,
        ]
        for i in 1..<8 where conditions[i] {
            if archive.careAchievements.insert("C0\(i)").inserted {
                if [3, 5, 7].contains(i) {
                    archive.eggs += 1
                    archive.eggSources.append(CompanionCatalog.care[i].title)
                }
                if let cosmetic = [1: 1, 2: 2, 4: 3, 6: 4][i] { archive.cosmetics.insert(cosmetic) }
            }
        }
    }
    func evolve(_ form: Int) {
        guard session == nil else {
            notice = "请结算当前局后再切换形态。"
            return
        }
        previousForm = pet?.form
        mutatePet { if $0.unlockedForms.contains(form) { $0.form = form } }
        signal("evolve")
        save()
    }
    func accessory(_ id: Int) {
        guard let pet, archive.cosmetics.contains(id) else { return }
        var items = archive.accessories[pet.id, default: []]
        if items.contains(id) { items.remove(id) } else { items.insert(id) }
        archive.accessories[pet.id] = items
        save()
    }
    func skin(_ game: CompanionGame, enabled: Bool) {
        var p = progress(game)
        p.skin = enabled
        setProgress(p, game: game)
        save()
    }
    func reset(gamesOnly: Bool) {
        session?.pause()
        if gamesOnly {
            archive.session = nil
            archive.snake = .init()
            archive.flight = .init()
        } else {
            archive = .init()
        }
        writable = true
        lastResult = nil
        notice = nil
        save()
    }
    func exportArchive() {
        pause()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NotchTriage-伙伴.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let target = panel.url {
            do {
                let data = try JSONEncoder().encode(archive)
                try data.write(to: target, options: .atomic)
            } catch { notice = "导出失败：\(error.localizedDescription)" }
        }
    }
    func importArchive() {
        pause()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let incoming = try Self.read(source)
            let alert = NSAlert()
            alert.messageText = "导入伙伴存档？"
            alert.informativeText =
                "将替换当前 \(archive.pets.count) 只精灵，导入 \(incoming.pets.count) 只及其游戏进度。当前存档会保留备份。"
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            session?.pause()
            archive = incoming
            archive.session?.pause()
            writable = true
            lastResult = nil
            save()
        } catch { notice = "未导入：\(error.localizedDescription)" }
    }
    func save() {
        guard writable else { return }
        do {
            archive.lastSaved = Date()
            let data = try JSONEncoder().encode(archive)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let old = try? Data(contentsOf: url),
                (try? Self.read(url)) != nil
            {
                try old.write(to: url.appendingPathExtension("backup"), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
        } catch { notice = "伙伴进度暂未保存：\(error.localizedDescription)" }
    }
    private static func read(_ url: URL) throws -> CompanionArchive {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let a = try JSONDecoder().decode(CompanionArchive.self, from: data)
        let progress = [a.snake, a.flight]
        guard a.version == 1, a.eggs >= 0, a.eggs < 100000, a.pets.count < 1000,
            Set(a.pets.map(\.id)).count == a.pets.count,
            a.selected == nil || a.pets.contains(where: { $0.id == a.selected }),
            (2...4).contains(a.preferences.scale), a.preferences.dim.isFinite,
            (0...0.25).contains(a.preferences.dim),
            a.pets.allSatisfy({
                (0..<3).contains($0.family) && (0..<4).contains($0.form)
                    && $0.unlockedForms.allSatisfy { (0..<4).contains($0) }
                    && [$0.energy, $0.satiety, $0.cleanliness, $0.mood].allSatisfy {
                        $0.isFinite && (0...100).contains($0)
                    }
            }),
            progress.allSatisfy({
                $0.xp.count == 4 && $0.xp.allSatisfy { (0...1800).contains($0) } && $0.equipment.count <= 2
                    && ($0.equipment + Array($0.owned)).allSatisfy { (1...8).contains($0) }
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        let prefs = a.preferences
        guard
            [prefs.speed, prefs.effects, prefs.petVolume, prefs.gameVolume, prefs.positionX, prefs.positionY]
                .allSatisfy({ $0.isFinite }),
            (15...60).contains(prefs.speed), (0...1.5).contains(prefs.effects),
            [prefs.petVolume, prefs.gameVolume, prefs.positionX, prefs.positionY].allSatisfy({
                (0...1).contains($0)
            }),
            prefs.banned.count <= 64,
            prefs.banned.allSatisfy({
                [$0.x, $0.y, $0.width, $0.height].allSatisfy({ $0.isFinite && (0...1).contains($0) })
            }),
            a.eggSources.count == a.eggs,
            a.pets.allSatisfy({
                (0...1000).contains($0.bond) && (0...200).contains($0.growth) && $0.waste <= 2
                    && $0.activeMinutes.isFinite && $0.activeMinutes >= 0 && $0.restMinutes.isFinite
                    && $0.digestion >= 0 && $0.digestion < 100000
                    && $0.wasteObjects.allSatisfy({
                        [$0.x, $0.y].allSatisfy({ $0.isFinite && (0...1).contains($0) })
                    })
            }),
            progress.allSatisfy({
                $0.totals.values.allSatisfy({ (0...1_000_000_000).contains($0) })
                    && Set($0.equipment).count == $0.equipment.count
                    && $0.equipment.allSatisfy({ $0 >= 1 && $0 <= 8 && $0 != 0 })
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        for (game, p) in zip(CompanionGame.allCases, progress) {
            for item in p.equipment {
                if !p.owned.contains(item)
                    || CompanionCatalog.relics(game)[item - 1].conflicts.map({ p.equipment.contains($0) })
                        == true
                {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        if let s = a.session {
            func point(_ p: CompanionPoint) -> Bool {
                p.x.isFinite && p.y.isFinite && abs(p.x) < 10000 && abs(p.y) < 10000
            }
            guard (0..<3).contains(s.family), (0..<4).contains(s.form), s.random != 0, s.wave <= 100000,
                (0..<4).contains(s.direction),
                s.queue.allSatisfy({ (0..<4).contains($0) }),
                s.candidates.allSatisfy({ (1...8).contains($0) }), s.temporary.count <= 6,
                s.permanent.count <= 2, s.counts.values.allSatisfy({ (0...1_000_000_000).contains($0) }),
                s.xp.allSatisfy({ (0...1_000_000_000).contains($0) }), s.particles.count <= 200,
                s.volleys.count <= 64, s.food.count <= 2,
                (s.snake + s.food + [s.player] + s.supplies).allSatisfy(point),
                (s.shots + s.bullets).allSatisfy({ point($0.position) && point($0.velocity) }),
                s.enemies.allSatisfy({
                    point($0.position) && $0.hp.isFinite && $0.maxHP.isFinite && $0.maxHP > 0
                }),
                [
                    s.recharge, s.stepClock, s.waveClock, s.spawnClock, s.fireClock, s.slowUntil,
                    s.invulnerableUntil, s.bossEntrance,
                ].allSatisfy({ $0.isFinite && $0 >= 0 }),
                a.pets.contains(where: { $0.id == s.petID }), s.levels.count == 4, s.xp.count == 4,
                s.levels.allSatisfy({ (1...10).contains($0) }), !s.snake.isEmpty, s.snake.count <= 600,
                s.wave > 0, s.time.isFinite, s.time >= 0, s.enemies.count <= 40, s.bullets.count <= 180,
                s.shots.count <= 96, s.permanent.allSatisfy({ (1...8).contains($0) }),
                s.temporary.allSatisfy({ (1...8).contains($0.key) && (1...3).contains($0.value) }),
                s.pool.allSatisfy({ (1...8).contains($0) }),
                s.enemies.allSatisfy({ (1...7).contains($0.kind) })
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        return a
    }
}
