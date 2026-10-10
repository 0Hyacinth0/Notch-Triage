import Foundation

struct CompanionWaste: Codable, Identifiable {
    var id = UUID()
    var x: Double, y: Double
    var inNest = false
}

struct CompanionPet: Codable, Identifiable {
    var id = UUID()
    var family: Int
    var name: String
    var energy = 80.0, satiety = 75.0, cleanliness = 90.0, mood = 75.0
    var bond = 0, growth = 0
    var days: Set<String> = []
    var dailyGrowth: [String: Int] = [:]
    var dailyCounts: [String: Int] = [:]
    var cooldowns: [String: Double] = [:]
    var activeMinutes = 0.0, restMinutes = 0.0, lastPoop = 0.0
    var digestion = 0, meals = 0, cleans = 0
    var wasteObjects: [CompanionWaste] = []
    var waste: Int { wasteObjects.count }
    var autoResting = false
    var form = 0
    var unlockedForms: Set<Int> = [0]
    var stage: Int { growth >= 90 && days.count >= 3 ? 2 : growth >= 25 ? 1 : 0 }
    var stageTitle: String { ["幼体", "成长期", "成年"][stage] }
    var familyTitle: String { CompanionCatalog.families[family] }
    var formTitle: String { CompanionCatalog.forms[family][form] }
}

enum CompanionGame: String, Codable, CaseIterable, Identifiable {
    case snake, flight
    var id: String { rawValue }
    var title: String { self == .snake ? "贪吃蛇" : "星灯航行" }
    var prefix: String { self == .snake ? "S" : "F" }
    var skillPrefix: String { self == .snake ? "ST" : "FT" }
}

struct CompanionProgress: Codable {
    var xp = [Int](repeating: 0, count: 4)
    var equipment: [Int] = []
    var owned: Set<Int> = []
    var achievements: Set<String> = []
    var totals: [String: Int] = [:]
    var best = 0
    var skin = false
    func level(_ skill: Int) -> Int {
        (1...10).last { xp[skill] >= 20 * ($0 - 1) * $0 } ?? 1
    }
}

struct CompanionPreferences: Codable {
    var enabled = false, inNest = false, resting = false
    var scale = 2, screenID: UInt32 = 0
    var speed = 35.0, dim = 0.10, effects = 1.0
    var reduceMotion = false, petSound = false, gameSound = false
    var bubbleWave = false, cushion = false
    var petVolume = 0.3, gameVolume = 0.2
    var positionX = 0.5, positionY = 0.25
    var banned: [CompanionRect] = []
}
struct CompanionRect: Codable, Identifiable {
    var id = UUID()
    var x: Double, y: Double, width: Double, height: Double
}
struct CompanionArchive: Codable {
    var version = 1
    var pets: [CompanionPet] = []
    var selected: UUID?
    var eggs = 0, duplicateStreak = 0
    var eggSources: [String] = []
    var careAchievements: Set<String> = []
    var cosmetics: Set<Int> = []
    var accessories: [UUID: Set<Int>] = [:]
    var snake = CompanionProgress(), flight = CompanionProgress()
    var preferences = CompanionPreferences()
    var session: CompanionSession?
    var lastSaved = Date()
    var snakeUnlocked = false, flightUnlocked = false
}

struct CompanionRelic: Identifiable {
    let game: CompanionGame, number: Int, name: String, effect: String, target: String
    var id: String { "\(game.prefix)0\(number)" }
    var conflicts: Int? {
        game == .snake ? (number == 3 ? 8 : number == 8 ? 3 : nil) : (number == 2 ? 7 : number == 7 ? 2 : nil)
    }
}
struct CompanionSkill: Identifiable {
    let game: CompanionGame, number: Int, name: String, source: String
    var id: String { "\(game.skillPrefix)0\(number + 1)" }
    func effect(_ level: Int) -> String {
        if game == .snake {
            return [
                "自主前瞻 \(level + 2) 步", "尾部通路判断 \(level + 3) 步",
                "节奏石延长 \(String(format: "%.1f", Double(level - 1) * 0.1)) 秒", "每 \(52 - level * 2) 份食物回充一次",
            ][number]
        }
        return [
            "目标预判 \(String(format: "%.1f", Double(level - 1) * 0.1)) 秒",
            "威胁预判 \(String(format: "%.2f", 0.20 + Double(level) * 0.05)) 秒", "直接弹道伤害 +\(level - 1)%",
            "护盾每 \(92 - level * 2) 秒回充",
        ][number]
    }
}
struct CompanionAchievement: Identifiable {
    let id: String, title: String, target: String, reward: String
}

enum CompanionCatalog {
    static let families = ["团芽", "云绒", "灯芽"]
    static let forms = [["芽点", "芽球", "青团", "花铃"], ["绒点", "棉团", "奶云", "星绒"], ["灯豆", "灯团", "暖灯", "月灯"]]
    static let skills: [CompanionSkill] = [
        .init(game: .snake, number: 0, name: "觅食", source: "吃一份真实食物 +2 经验"),
        .init(game: .snake, number: 1, name: "避险", source: "安全离开受限区域 +1 经验"),
        .init(game: .snake, number: 2, name: "节奏", source: "减速期间吃食物 +3 经验"),
        .init(game: .snake, number: 3, name: "守护", source: "护符抵消非法移动 +4 经验"),
        .init(game: .flight, number: 0, name: "瞄准", source: "每 5 次有效直接命中 +2 经验"),
        .init(game: .flight, number: 1, name: "闪避", source: "躲过一枚真实威胁弹 +1 经验"),
        .init(game: .flight, number: 2, name: "炮术", source: "击毁普通敌人 +2，首领 +10 经验"),
        .init(game: .flight, number: 3, name: "护盾", source: "护盾实际抵消伤害 +4 经验"),
    ]
    static func relics(_ game: CompanionGame) -> [CompanionRelic] {
        let names =
            game == .snake
            ? ["留步护符", "磁果石", "双生果籽", "节奏石", "回响贝", "远望镜", "星糖罐", "空间铃"]
            : ["分光晶", "护盾芯", "疾风翎", "穿透针", "余烬心", "星磁环", "补给囊", "时缓核"]
        let effects =
            game == .snake
            ? [
                "取消非法移动，给予 0.75 秒纠正；容量 1/2/3", "食物基础分 +10/20/30%", "每 10/8/6 份食物生成奖励果；与空间铃互斥",
                "每 8/7/6 份食物减速 6/8/10 秒", "25 步内连续进食额外 +2/4/6 分", "自主路径前瞻 +2/4/6 步", "每 12/10/8 份食物额外 +30 分",
                "每 10/8/6 份食物缩短一格；与双生果籽互斥",
            ]
            : [
                "每次齐射增加 1/2/3 对侧弹", "护盾容量 1/2/3 层；与补给囊互斥", "移动速度 +8/16/24%", "直接弹额外穿透 1/2/3 个目标",
                "击毁敌人产生 20/28/36 伤害爆炸", "补给拾取半径 2/3/4", "每 6/5/4 波恢复 1 生命；与护盾芯互斥",
                "每 8/7/6 次真实闪避缓速敌人，冷却 20 秒",
            ]
        let targets =
            game == .snake
            ? [
                "单局吃 5 份食物", "累计吃 20 份", "单局吃 15 份", "累计吃 50 份", "累计转向 100 次", "觅食达到 L3", "累计吃 100 份",
                "单局吃 30 份",
            ]
            : [
                "累计击毁 10 个敌人", "累计完成 3 波", "累计完成 6 波", "累计击毁 5 个装甲机", "首次击败首领", "累计拾取 10 份补给", "累计完成 12 波",
                "累计击败 3 个首领",
            ]
        return (1...8).map {
            .init(
                game: game, number: $0, name: names[$0 - 1], effect: effects[$0 - 1], target: targets[$0 - 1])
        }
    }
    static let care: [CompanionAchievement] = [
        .init(id: "C00", title: "初次相遇", target: "首次启用桌面伙伴", reward: "精灵蛋 ×1"),
        .init(id: "C01", title: "第一顿饭", target: "有效正餐一次", reward: "奶油小围兜"),
        .init(id: "C02", title: "小小清洁员", target: "有效清洁累计 5 次", reward: "泡泡挥手"),
        .init(id: "C03", title: "长大啦", target: "首只精灵成年", reward: "精灵蛋 ×1"),
        .init(id: "C04", title: "熟悉的朋友", target: "任一精灵亲密度达到 100", reward: "薄荷围巾"),
        .init(id: "C05", title: "两种模样", target: "解锁两个成年形态", reward: "精灵蛋 ×1"),
        .init(id: "C06", title: "住满小窝", target: "集齐三个精灵家族", reward: "浅蓝软垫"),
        .init(id: "C07", title: "一起成长", target: "至少两只精灵成年", reward: "精灵蛋 ×1"),
    ]
}
