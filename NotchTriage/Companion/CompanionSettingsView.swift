import AppKit
import SwiftUI

struct CompanionSettingsView: View {
    @ObservedObject var store: CompanionStore
    @AppStorage("NotchTriage.Companion.selectedSection") private var section = "我的伙伴"
    @State private var game: CompanionGame = .snake
    @State private var gameTab = "开始"
    @State private var nestTab = "我的精灵"
    @State private var newName = ""
    @State private var pendingPet: UUID?
    @State private var resetMode: Bool?
    @State private var demoID: UUID?
    @State private var preview = ""
    @State private var previewStart = Date.distantPast
    private let sections = ["我的伙伴", "精灵小窝", "小游戏", "外观与动效", "桌面与数据"]
    private func pref<T>(_ path: WritableKeyPath<CompanionPreferences, T>) -> Binding<T> {
        .init(
            get: { store.preferences[keyPath: path] },
            set: { value in store.editPreferences { $0[keyPath: path] = value } })
    }
    var body: some View {
        SettingsPage(title: "桌面伙伴", subtitle: "住在桌面里的像素小精灵，陪你长大，也会自己玩游戏。", symbol: "pawprint") {
            Toggle("开启桌面伙伴", isOn: Binding(get: { store.preferences.enabled }, set: store.enable))
                .toggleStyle(.switch)
            if let notice = store.notice {
                HStack {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.clearNotice()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }.buttonStyle(.plain)
                }
            }
            Picker("伙伴设置", selection: $section) { ForEach(sections, id: \.self) { Text($0) } }.pickerStyle(
                .segmented)
            if !store.preferences.enabled {
                Text("关闭时停止活动，已有精灵、收藏和挂起游戏仍会保留。离线不会失去成长。").font(.caption).foregroundStyle(.secondary)
            }
            switch section {
            case "我的伙伴": companion
            case "精灵小窝": nest
            case "小游戏": games
            case "外观与动效": appearance
            default: desktop
            }
        }
        .onChange(of: game) { _, _ in demoID = nil }
        .confirmationDialog(
            "当前还有一局游戏",
            isPresented: Binding(get: { pendingPet != nil }, set: { if !$0 { pendingPet = nil } }),
            titleVisibility: .visible
        ) {
            Button("继续原局") {
                store.emerge()
                section = "小游戏"
                pendingPet = nil
            }
            Button("结束并结算后切换") {
                if let id = pendingPet {
                    store.finish()
                    store.select(id)
                }
                pendingPet = nil
            }
            Button("取消", role: .cancel) { pendingPet = nil }
        }
        .confirmationDialog(
            "确认重置？", isPresented: Binding(get: { resetMode != nil }, set: { if !$0 { resetMode = nil } }),
            titleVisibility: .visible
        ) {
            Button(resetMode == true ? "重置两款游戏进度" : "重置全部伙伴数据", role: .destructive) {
                if let mode = resetMode { store.reset(gamesOnly: mode) }
                resetMode = nil
            }
            Button("取消", role: .cancel) { resetMode = nil }
        } message: {
            Text(resetMode == true ? "清除训练、永久遗物、游戏成就及当前局；保留精灵与已经获得的蛋和外观。" : "清除所有精灵、蛋、外观、训练与游戏存档。建议先导出备份。")
        }
    }
    @ViewBuilder private var companion: some View {
        if let pet = store.pet {
            SettingsGroup(title: "\(pet.name) · \(pet.stageTitle)") {
                HStack(spacing: 20) {
                    CompanionPortrait(pet: pet).frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(pet.familyTitle) · \(pet.formTitle)").font(.headline)
                        Text(
                            store.preferences.inNest
                                ? "正在小窝里休息" : store.preferences.resting ? "正在休息" : "正在桌面陪伴"
                        ).foregroundStyle(.secondary)
                        HStack {
                            TextField("名字", text: $newName).frame(width: 150)
                            Button("改名") {
                                if !newName.isEmpty {
                                    store.rename(newName)
                                    newName = ""
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 20) {
                    metric("精力", value: pet.energy)
                    metric("心情", value: pet.mood)
                    metric("亲密度", value: Double(pet.bond), total: 1000)
                }
                HStack {
                    Button("摸摸") { store.care("pet") }
                    Button("喂食") { store.care("meal") }
                    Button("点心") { store.care("snack") }
                    Button(store.preferences.resting ? "叫醒" : "休息") { store.rest() }
                    Button(store.preferences.inNest ? "出来玩" : "回窝") {
                        if store.preferences.inNest { store.emerge() } else { store.nest() }
                    }
                }.disabled(!store.preferences.enabled)
                DisclosureGroup("照料详情") {
                    HStack {
                        metric("饱腹", value: pet.satiety)
                        metric("清洁", value: pet.cleanliness)
                    }
                    HStack {
                        Text("待清理 \(pet.waste) 份").font(.caption)
                        Spacer()
                        Button("洗澡") { store.care("bath") }
                        Button("全部清理") { store.care("clean") }.disabled(pet.waste == 0)
                    }
                    Text("照料免费；吃饱会婉拒。离线不扣状态，不会生病或死亡。").font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(title: "成长与进化") {
                ProgressView(value: Double(min(90, pet.growth)), total: 90)
                Text("成长 \(pet.growth)/90 · 有效成长日 \(pet.days.count)/3").font(.caption.monospacedDigit())
                Text("成长 25 进入成长期；90 且有 3 个有效成长日成年。一天成长至少 10 并有一次照料，计为有效成长日。").font(.caption).foregroundStyle(
                    .secondary)
                ForEach(0..<4, id: \.self) { form in
                    HStack {
                        CompanionPortrait(pet: formPet(pet, form)).frame(width: 38, height: 38).opacity(
                            pet.unlockedForms.contains(form) ? 1 : 0.25)
                        VStack(alignment: .leading) {
                            Text(CompanionCatalog.forms[pet.family][form])
                            Text(condition(pet, form)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(pet.form == form ? "当前形态" : pet.unlockedForms.contains(form) ? "切换" : "未解锁") {
                            store.evolve(form)
                        }.disabled(!pet.unlockedForms.contains(form) || pet.form == form)
                    }
                }
            }
        } else {
            welcome
        }
        SettingsGroup(title: "养成目标") {
            ForEach(CompanionCatalog.care) { row in
                achievement(row, done: store.archive.careAchievements.contains(row.id))
            }
        }
    }
    private func metric(_ title: String, value: Double, total: Double = 100) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: value, total: total).tint(.mint)
            Text("\(Int(value))/\(Int(total))").font(.caption.monospacedDigit())
        }.frame(maxWidth: .infinity)
    }
    private var welcome: some View {
        SettingsGroup(title: "第一位小伙伴") {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.mint)
            Text("一枚蛋，一段新的陪伴").font(.headline)
            Text("开启后领取第一枚蛋，随机遇见团芽、云绒或灯芽。以后通过照料和游戏成就继续获得蛋。").foregroundStyle(.secondary)
            Button("孵化精灵蛋 · 剩余 \(store.archive.eggs)") { store.hatch() }.disabled(
                !store.preferences.enabled || store.archive.eggs == 0)
        }
    }
    private func formPet(_ pet: CompanionPet, _ form: Int) -> CompanionPet {
        var p = pet
        p.form = form
        return p
    }
    private func condition(_ pet: CompanionPet, _ form: Int) -> String {
        if form == 0 { return "初次孵化" }
        if form == 1 { return "成长达到 25" }
        let personal = ["正餐累计 3 次", "主动休息累计 20 分钟", "有效清洁累计 2 次"][pet.family]
        let skills = ["觅食或炮术 L3", "避险或闪避 L3", "节奏或护盾 L3"][pet.family]
        return "成年 + 亲密度 \(form==2 ? 20 : 50) + \(form==2 ? personal : skills)"
    }
    private var nest: some View {
        VStack(spacing: 18) {
            SettingsGroup(title: "精灵小窝") {
                Picker("小窝", selection: $nestTab) {
                    Text("我的精灵").tag("我的精灵")
                    Text("图鉴").tag("图鉴")
                    Text("精灵蛋").tag("精灵蛋")
                }.pickerStyle(.segmented)
                if store.preferences.cushion {
                    RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.13)).overlay(
                        Text("浅蓝软垫 · 小窝装饰").font(.caption).foregroundStyle(.secondary)
                    ).frame(height: 36)
                }
                if nestTab == "我的精灵" {
                    if store.archive.pets.isEmpty { Text("还没有孵化精灵。") }
                    ForEach(store.archive.pets) { pet in
                        HStack {
                            CompanionPortrait(pet: pet).frame(width: 48, height: 48)
                            VStack(alignment: .leading) {
                                Text(pet.name)
                                Text("\(pet.stageTitle) · \(pet.formTitle)").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Spacer()
                            Button(store.archive.selected == pet.id ? "当前伙伴" : "换它陪伴") {
                                if store.session != nil { pendingPet = pet.id } else { store.select(pet.id) }
                            }.disabled(store.archive.selected == pet.id)
                        }
                    }
                    if store.pet != nil {
                        Button(store.preferences.inNest ? "出来玩" : "回窝") {
                            if store.preferences.inNest { store.emerge() } else { store.nest() }
                        }
                    }
                } else if nestTab == "精灵蛋" {
                    Text("待孵化：\(store.archive.eggs) 枚").font(.headline)
                    Text("首次赠送，后续来自养成或游戏成就。孵化不要求联网，重复种类也可以保留。").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(store.archive.eggSources.enumerated()), id: \.offset) { entry in
                        Text("精灵蛋 · " + entry.element).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("孵化一枚") { store.hatch() }.disabled(
                        store.archive.eggs == 0 || !store.preferences.enabled)
                } else {
                    ForEach(0..<3, id: \.self) { family in
                        let owned = store.archive.pets.filter { $0.family == family }
                        VStack(alignment: .leading) {
                            Text(owned.isEmpty ? "未发现的精灵" : CompanionCatalog.families[family]).font(.headline)
                            HStack {
                                ForEach(0..<4, id: \.self) { form in
                                    let found = owned.contains { $0.unlockedForms.contains(form) }
                                    VStack {
                                        CompanionPortrait(
                                            pet: formPet(CompanionPet(family: family, name: ""), form)
                                        ).frame(width: 56, height: 56).opacity(found ? 1 : 0.12)
                                        Text(found ? CompanionCatalog.forms[family][form] : "?").font(
                                            .caption)
                                    }.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            }
            if let pet = store.pet, pet.waste > 0 {
                SettingsGroup(title: "小窝卫生区") {
                    HStack {
                        Text("\(pet.waste) 份待清理")
                        Spacer()
                        Button("全部清理") { store.care("clean") }
                    }
                }
            }
        }
    }
    private var games: some View {
        VStack(spacing: 18) {
            if let result = store.lastResult { SettingsGroup(title: "最近一局") { Text(result).font(.callout) } }
            if let s = store.session {
                SettingsGroup(title: "当前局 · \(s.game.title)") {
                    Text("\(s.score) 分 · \(s.manual ? "你在操作" : "它在玩") · \(s.paused ? "已暂停" : "进行中")")
                    HStack {
                        Button(s.paused ? "继续" : "暂停") {
                            if s.paused { store.resume() } else { store.pause() }
                        }.disabled(!s.candidates.isEmpty)
                        Button(s.manual ? "交还" : "接管") { store.handoff() }
                        Button("结束并结算") { store.finish() }
                    }
                    if !s.candidates.isEmpty {
                        Text("选择本局遗物").font(.headline)
                        ForEach(s.candidates, id: \.self) { number in
                            let relic = CompanionCatalog.relics(s.game)[number - 1]
                            Button {
                                store.choose(number)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("\(relic.name) · 本局 R\(s.rank(number)+1)").font(.headline)
                                    Text(relic.effect).font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                        }
                        if let pending = s.pendingReplacement {
                            Text("临时遗物已满，选择替换一件：")
                            ForEach(s.temporary.keys.sorted(), id: \.self) { number in
                                Button("替换 \(CompanionCatalog.relics(s.game)[number-1].name)") {
                                    store.choose(pending, replacing: number)
                                }
                            }
                        }
                    }
                    if !s.temporary.isEmpty {
                        Text(
                            "本局："
                                + s.temporary.keys.sorted().map {
                                    "\(CompanionCatalog.relics(s.game)[$0-1].name) R\(s.rank($0))"
                                }.joined(separator: " · ")
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Picker("游戏", selection: $game) { ForEach(CompanionGame.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            Picker("游戏详情", selection: $gameTab) {
                ForEach(["开始", "训练", "遗物", "成就"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            gameDetails
        }
    }
    @ViewBuilder private var gameDetails: some View {
        let p = store.progress(game)
        switch gameTab {
        case "训练":
            SettingsGroup(title: "共享训练 · 所有精灵共同进步") {
                ForEach(CompanionCatalog.skills.filter { $0.game == game }) { skill in
                    let level = p.level(skill.number)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(skill.name).font(.headline)
                            Spacer()
                            Text("L\(level)/10").monospacedDigit()
                        }
                        ProgressView(value: Double(p.xp[skill.number]), total: 1800)
                        Text(skill.effect(level)).font(.callout)
                        Text(skill.source + " · 结算后升级，下一局生效").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        case "遗物":
            SettingsGroup(title: "永久收藏 · 两个装备位") {
                Text("永久固定 R1；局内最多六种临时遗物，可升级到 R3。同名不重复装备。").font(.caption).foregroundStyle(.secondary)
                ForEach(CompanionCatalog.relics(game)) { relic in
                    HStack(alignment: .top) {
                        Image(systemName: p.owned.contains(relic.number) ? "sparkles" : "lock")
                            .foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(relic.name).font(.headline)
                            Text(relic.effect).font(.caption)
                            Text("永久获取：" + relic.target).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(p.equipment.contains(relic.number) ? "取下" : "装备") {
                            store.equip(relic.number, game: game)
                        }.disabled(!p.owned.contains(relic.number))
                    }.padding(.vertical, 4)
                }
            }
        case "成就":
            SettingsGroup(title: "目标与奖励") {
                ForEach(CompanionCatalog.relics(game)) { r in
                    achievement(
                        .init(
                            id: "\(game.prefix)C0\(r.number)", title: r.name, target: r.target,
                            reward: "永久遗物 · R1"), done: p.owned.contains(r.number))
                }
                achievement(
                    .init(id: "09", title: "一起坚持", target: "单局实际游玩 180 秒", reward: "精灵蛋 ×1"),
                    done: p.achievements.contains("\(game.prefix)C09"))
                achievement(
                    .init(
                        id: "10", title: "一起练习", target: game == .snake ? "累计吃 200 份食物" : "累计完成 24 波",
                        reward: "精灵蛋 ×1"), done: p.achievements.contains("\(game.prefix)C10"))
                achievement(
                    .init(
                        id: "11", title: "新的模样", target: game == .snake ? "单局吃 50 份食物" : "首次击败星灯核心",
                        reward: "游戏皮肤"), done: p.achievements.contains("\(game.prefix)C11"))
                achievement(
                    .init(
                        id: "12", title: "训练有成", target: game == .snake ? "觅食 L5" : "闪避 L5", reward: "精灵配饰"),
                    done: p.achievements.contains("\(game.prefix)C12"))
                Text(game == .snake ? "每累计新增 1000 份食物，再获一枚蛋。" : "每累计新增 30 次首领击败，再获一枚蛋。").font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            SettingsGroup(title: game.title) {
                Text(game == .snake ? "吃食物、变长、避撞。30×20 棋盘，从每步 220 ms 逐渐加速。" : "自动射击，移动躲避。3 点生命，敌人与首领按波次持续挑战。")
                Text("游戏位于桌面右下角，约 360 点宽。自己玩和接管共用同一局；失焦、全屏和回窝暂停，直到失败或主动结束结算。").font(.caption).foregroundStyle(.secondary)
                Text(
                    "最高 \(p.best) 分 · 装备 "
                        + (p.equipment.isEmpty
                            ? "暂无"
                            : p.equipment.map { CompanionCatalog.relics(game)[$0 - 1].name }.joined(
                                separator: "、"))
                ).font(.caption)
                HStack {
                    Button("让它玩") { store.startGame(game) }.buttonStyle(.borderedProminent)
                    Button("我来玩") { store.startGame(game, manual: true) }
                }.disabled(store.session != nil || !store.preferences.enabled)
                if !(game == .snake ? store.archive.snakeUnlocked : store.archive.flightUnlocked) {
                    Text(game == .snake ? "首只精灵成长到成长期后解锁。" : "首只精灵成年后解锁。").font(.caption).foregroundStyle(
                        .secondary)
                }
                Button("观看玩法演示") { demoID = UUID() }
                if let demoID {
                    CompanionGameDemo(store: store, game: game).id(demoID).frame(height: 200).clipShape(
                        RoundedRectangle(cornerRadius: 12))
                    Text("20 秒自主演示，不保存分数、训练或奖励。").font(.caption).foregroundStyle(.secondary)
                }
                Text("方向键 / WASD 移动 · 射击也可点击目标位置 · Esc 暂停").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func achievement(_ row: CompanionAchievement, done: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(
                done ? Color.mint : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                Text(row.target + " · " + row.reward).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical, 2)
    }
    private var appearance: some View {
        VStack(spacing: 18) {
            SettingsGroup(title: "动效预览") {
                if let pet = store.pet {
                    CompanionEffectPreview(
                        pet: pet, preferences: store.preferences, action: preview, start: previewStart,
                        accessories: store.archive.accessories[pet.id, default: []]
                    ).frame(height: 150)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(
                        [
                            "走路", "拖起", "挥手", "摸摸", "正餐", "点心", "洗澡", "清理", "休息", "叫醒", "睡觉", "伸懒腰", "回窝",
                            "进化", "命中爆炸",
                        ], id: \.self
                    ) { name in
                        Button(name) {
                            preview = name
                            previewStart = Date()
                        }
                    }
                }
                Text("预览不改变精灵状态或发放奖励。").font(.caption).foregroundStyle(.secondary)
            }
            SettingsGroup(title: "光效与运动") {
                slider("特效强度", value: pref(\.effects), range: 0...1.5)
                HStack {
                    ForEach(["低", "标准", "华丽"], id: \.self) { name in
                        Button(name) {
                            store.editPreferences { $0.effects = name == "低" ? 0.3 : name == "标准" ? 1 : 1.5 }
                        }
                    }
                }
                slider("小游戏区域暗化", value: pref(\.dim), range: 0...0.25)
                Toggle("减少动态效果", isOn: pref(\.reduceMotion))
            }
            SettingsGroup(title: "声音 · 默认安静") {
                Toggle("伙伴音效", isOn: pref(\.petSound))
                slider("伙伴音量", value: pref(\.petVolume), range: 0...1)
                Toggle("游戏音效", isOn: pref(\.gameSound))
                slider("游戏音量", value: pref(\.gameVolume), range: 0...1)
            }
            SettingsGroup(title: "已获得外观") {
                if store.archive.cosmetics.isEmpty { Text("通过照料与游戏目标解锁外观。") }
                ForEach([1, 3, 6, 8].filter { store.archive.cosmetics.contains($0) }, id: \.self) { id in
                    Toggle(
                        [1: "奶油小围兜", 3: "薄荷围巾", 6: "翠叶帽", 8: "星尾挂饰"][id]!,
                        isOn: Binding(
                            get: {
                                store.pet.map { store.archive.accessories[$0.id, default: []].contains(id) }
                                    ?? false
                            }, set: { _ in store.accessory(id) }))
                }
                if store.archive.cosmetics.contains(2) { Toggle("泡泡挥手动作", isOn: pref(\.bubbleWave)) }
                if store.archive.cosmetics.contains(4) { Toggle("小窝浅蓝软垫", isOn: pref(\.cushion)) }
                ForEach(CompanionGame.allCases) { g in
                    if store.archive.cosmetics.contains(g == .snake ? 5 : 7) {
                        Toggle(
                            g == .snake ? "果糖蛇皮肤" : "糖星号皮肤",
                            isOn: Binding(
                                get: { store.progress(g).skin }, set: { store.skin(g, enabled: $0) }))
                    }
                }
            }
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
    private var screenChoices: [(id: UInt32, name: String)] {
        NSScreen.screens.map {
            (
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    ?? 0, $0.localizedName
            )
        }
    }
    private var desktop: some View {
        VStack(spacing: 18) {
            SettingsGroup(title: "桌面活动") {
                Picker("显示器", selection: pref(\.screenID)) {
                    Text("自动选择刘海屏幕").tag(UInt32(0))
                    ForEach(screenChoices, id: \.id) { screen in Text(screen.name).tag(screen.id) }
                }
                Picker("像素大小", selection: pref(\.scale)) {
                    Text("小 · 2×").tag(2)
                    Text("中 · 3×").tag(3)
                    Text("大 · 4×").tag(4)
                }.pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    Text("漫游速度 · \(Int(store.preferences.speed)) pt/秒")
                    Slider(value: pref(\.speed), in: 15...60)
                }
                Text("全屏应用中隐藏；手动游戏切走暂停，回到游戏后点击继续。没有实体刘海时，屏幕顶部仍可回窝。").font(.caption).foregroundStyle(
                    .secondary)
                DisclosureGroup("漫游禁入区域") {
                    Text("按屏幕比例设置，精灵会避开区域；已自动避开菜单栏与 Dock。").font(.caption).foregroundStyle(.secondary)
                    CompanionRegionEditor(store: store).frame(height: 180)
                    ForEach(store.preferences.banned) { r in
                        HStack {
                            Text(
                                "区域 \(Int(r.x*100))%, \(Int(r.y*100))% · \(Int(r.width*100))%×\(Int(r.height*100))%"
                            ).font(.caption)
                            Spacer()
                            Button("移除") { store.editPreferences { $0.banned.removeAll { $0.id == r.id } } }
                        }
                    }
                    Button("保护屏幕中央工作区") {
                        store.editPreferences {
                            $0.banned.append(.init(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
                        }
                    }
                    Button("保护刘海下方歌词区") {
                        store.editPreferences {
                            $0.banned.append(.init(x: 0.15, y: 0.8, width: 0.7, height: 0.2))
                        }
                    }
                }
            }
            SettingsGroup(title: "本机数据") {
                Text("伙伴与游戏进度保存在本机，自动保存并保留上次备份；无需账户或服务器。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("导出存档") { store.exportArchive() }
                    Button("导入存档…") { store.importArchive() }
                }
                Divider()
                Button("重置游戏进度…", role: .destructive) { resetMode = true }
                Button("重置全部伙伴数据…", role: .destructive) { resetMode = false }
            }
        }
    }
}

private struct CompanionEffectPreview: NSViewRepresentable {
    let pet: CompanionPet, preferences: CompanionPreferences, action: String, start: Date
    let accessories: Set<Int>
    func makeNSView(context: Context) -> CompanionPreviewCanvas { CompanionPreviewCanvas() }
    func updateNSView(_ view: CompanionPreviewCanvas, context: Context) {
        view.pet = pet
        view.preferences = preferences
        view.action = action
        view.start = start
        view.accessories = accessories
        view.animate()
    }
    static func dismantleNSView(_ view: CompanionPreviewCanvas, coordinator: ()) { view.timer?.invalidate() }
}
private final class CompanionPreviewCanvas: NSView {
    var pet: CompanionPet?, preferences = CompanionPreferences(), action = "", start = Date.distantPast
    var timer: Timer?
    var accessories: Set<Int> = []
    override func draw(_ dirtyRect: NSRect) {
        guard let pet else { return }
        let age = Date().timeIntervalSince(start)
        let active = age < 3.2
        NSColor.black.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        let reduced = preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let nesting = active && action == "回窝"
        let progress = min(1, age / (reduced ? 0.25 : 1.35))
        let edge = bounds.maxY - 24
        let width = nesting ? 80.0 : 100.0
        let y = nesting ? progress * 125 : 0
        let rect = NSRect(
            x: bounds.midX - width / 2, y: bounds.midY - width / 2 + y, width: width, height: width)
        if nesting {
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: bounds.midX - 85, y: edge, width: 170, height: 30), xRadius: 12,
                yRadius: 12
            ).fill()
            NSColor.systemMint.withAlphaComponent(0.8).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: bounds.midX - 22, y: edge + 1, width: 44, height: 3), xRadius: 2,
                yRadius: 2
            ).fill()
        }
        let pose: CompanionPose =
            active
            ? [
                "走路": .walk, "拖起": .carried, "挥手": .wave,
                "睡觉": .sleep, "休息": .sleep, "叫醒": .stretch, "伸懒腰": .stretch,
            ][action] ?? .idle : .idle
        NSGraphicsContext.saveGraphicsState()
        if nesting { NSRect(x: 0, y: 0, width: bounds.width, height: edge).clip() }
        CompanionArtwork.drawPet(
            pet, rect: rect, time: active ? age : 0, effects: preferences.effects,
            reduced: reduced,
            action: [
                "摸摸": "pet", "回窝": "nest", "进化": "evolve", "命中爆炸": "result", "正餐": "meal", "点心": "snack",
                "洗澡": "bath", "清理": "clean", "休息": "rest", "叫醒": "rest",
            ][action] ?? action,
            actionAge: active ? age : 99, accessories: accessories, pose: pose,
            lean: pose == .carried ? sin(age * 7) * 14 : 0)
        NSGraphicsContext.restoreGraphicsState()
        if active && preferences.bubbleWave && (pose == .wave || action == "摸摸") {
            NSColor.systemCyan.withAlphaComponent(max(0, 1 - age.truncatingRemainder(dividingBy: 1.2) / 1.2))
                .setStroke()
            for i in 0..<4 {
                NSBezierPath(
                    ovalIn: NSRect(
                        x: rect.minX + Double(i) * 22,
                        y: rect.midY + age.truncatingRemainder(dividingBy: 1.2) * 25, width: 5, height: 5)
                ).stroke()
            }
        }
    }
    func animate() {
        needsDisplay = true
        timer?.invalidate()
        guard Date().timeIntervalSince(start) < 3.2 else { return }
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else {
                    t.invalidate()
                    return
                }
                self.needsDisplay = true
                if Date().timeIntervalSince(self.start) > 3.2 { t.invalidate() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
}

struct CompanionNestEntry: View {
    @ObservedObject var store: CompanionStore
    let open: () -> Void
    @State private var draggingOut = false
    var body: some View {
        Button {
            open()
        } label: {
            Image(systemName: "pawprint.fill").foregroundStyle(
                store.preferences.enabled ? Color.mint : Color.secondary)
        }.buttonStyle(.plain).help(store.preferences.inNest ? "精灵小窝 · 伙伴在窝里" : "桌面伙伴")
            .simultaneousGesture(
                DragGesture(minimumDistance: 4).onChanged { _ in
                    guard store.preferences.enabled, store.preferences.inNest || draggingOut else { return }
                    draggingOut = true
                    store.desktopDragHandler?(NSEvent.mouseLocation)
                }.onEnded { _ in
                    if draggingOut { store.desktopDragHandler?(nil) }
                    draggingOut = false
                }
            )
            .contextMenu {
                Button(store.preferences.inNest ? "出来玩" : "回窝") {
                    if store.preferences.inNest { store.emerge() } else { store.nest() }
                }
                Button("精灵小窝") { open() }
            }
    }
}

private struct CompanionRegionEditor: View {
    @ObservedObject var store: CompanionStore
    @State private var anchor: CGPoint?
    @State private var cursor: CGPoint?
    private func rectangle(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        .init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    var body: some View {
        GeometryReader { g in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05))
                VStack {
                    Text("拖动划出禁入区域").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("桌面示意 · 不读取工作内容").font(.caption2).foregroundStyle(.secondary)
                }.padding(10)
                ForEach(store.preferences.banned) { r in
                    Rectangle().fill(Color.mint.opacity(0.18)).overlay(
                        Rectangle().stroke(Color.mint.opacity(0.6), lineWidth: 1)
                    )
                    .frame(width: r.width * g.size.width, height: r.height * g.size.height)
                    .position(
                        x: (r.x + r.width / 2) * g.size.width, y: (1 - r.y - r.height / 2) * g.size.height)
                }
                if let anchor, let cursor {
                    let r = rectangle(anchor, cursor)
                    Rectangle().fill(Color.blue.opacity(0.18)).overlay(
                        Rectangle().stroke(Color.blue, lineWidth: 1)
                    ).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3).onChanged { value in
                    if anchor == nil { anchor = value.startLocation }
                    cursor = CGPoint(
                        x: min(g.size.width, max(0, value.location.x)),
                        y: min(g.size.height, max(0, value.location.y)))
                }.onEnded { _ in
                    if let anchor, let cursor, store.preferences.banned.count < 64 {
                        let r = rectangle(anchor, cursor)
                        if r.width > 8 && r.height > 8 {
                            store.editPreferences {
                                $0.banned.append(
                                    .init(
                                        x: r.minX / g.size.width, y: 1 - r.maxY / g.size.height,
                                        width: r.width / g.size.width, height: r.height / g.size.height))
                            }
                        }
                    }
                    anchor = nil
                    cursor = nil
                })
        }
    }
}

private struct CompanionGameDemo: NSViewRepresentable {
    let store: CompanionStore
    let game: CompanionGame
    @MainActor final class Coordinator {
        var timer: Timer?
        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CompanionGameView {
        let view = CompanionGameView(store: store)
        view.demoSession = CompanionSession(pet: UUID(), game: game, progress: .init())
        var elapsed = 0.0
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak view] t in
            MainActor.assumeIsolated {
                guard let view else {
                    t.invalidate()
                    return
                }
                elapsed += 1.0 / 30
                view.demoSession?.update(1.0 / 30)
                view.needsDisplay = true
                if elapsed >= 20 || view.demoSession?.finished == true { t.invalidate() }
            }
        }
        return view
    }
    func updateNSView(_ view: CompanionGameView, context: Context) {}
    static func dismantleNSView(_ view: CompanionGameView, coordinator: Coordinator) { coordinator.stop() }
}
