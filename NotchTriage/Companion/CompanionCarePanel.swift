import AppKit
import SwiftUI

/// The companion's own care surface. The settings window remains available for
/// deeper game training, relics, desktop placement and archive management.
struct CompanionCarePanel: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var visibility: CompanionCareVisibility
    let dismiss: () -> Void
    @State private var tab = "照料"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("伙伴小屋", systemImage: "pawprint.fill").font(.headline)
                Spacer()
                Button {
                    store.openSettings()
                    dismiss()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain).help("伙伴完整设置")
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("关闭小屋")
            }
            if let pet = store.pet {
                HStack(spacing: 18) {
                    TimelineView(
                        .animation(
                            minimumInterval: 0.12,
                            paused: !visibility.visible || reduceMotion || store.preferences.reduceMotion)
                    ) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        Image(
                            nsImage: CompanionArtwork.sprite(
                                family: pet.family, form: pet.form,
                                blink: t.truncatingRemainder(dividingBy: 4) < 0.14,
                                pose: store.preferences.resting || pet.autoResting ? .sleep : .idle,
                                frame: Int(t * 3) % 4)
                        )
                        .resizable().interpolation(.none).scaledToFit()
                    }
                    .frame(width: 90, height: 90)
                    .background(
                        Color(nsColor: CompanionArtwork.palettes[pet.family]).opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pet.name).font(.title2.weight(.semibold)).lineLimit(1)
                        Text("\(pet.familyTitle) · \(pet.stageTitle) · \(pet.formTitle)")
                            .font(.caption).foregroundStyle(.secondary)
                        Label(
                            store.preferences.resting || pet.autoResting ? "正在休息" : "在你身边",
                            systemImage: store.preferences.resting || pet.autoResting
                                ? "moon.zzz" : "heart.fill"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Picker("小屋页面", selection: $tab) {
                    ForEach(["照料", "成长", "伙伴"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if tab == "照料" {
                            HStack(spacing: 12) {
                                meter("精力", pet.energy, .mint)
                                meter("饱腹", pet.satiety, .orange)
                            }
                            HStack(spacing: 12) {
                                meter("清洁", pet.cleanliness, .cyan)
                                meter("心情", pet.mood, .pink)
                            }
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                                ], spacing: 10
                            ) {
                                care("摸摸", "hand.wave", "pet")
                                care("正餐", "fork.knife", "meal")
                                care("点心", "birthday.cake", "snack")
                                care("洗澡", "bubbles.and.sparkles", "bath")
                                care(pet.waste > 0 ? "清理 · \(pet.waste)" : "清理", "sparkles", "clean")
                                Button {
                                    store.rest()
                                } label: {
                                    tile(store.preferences.resting ? "叫醒" : "休息", "moon.zzz")
                                }.buttonStyle(.plain)
                            }
                            Text("离线不会失去成长。照料有冷却，陪伴也会慢慢增进亲密度。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if tab == "成长" {
                            meter("亲密度", Double(pet.bond) / 10, .pink)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("成长 \(pet.growth) · 有效成长日 \(pet.days.count)").font(
                                    .subheadline.weight(.medium))
                                Text("成长 25 进入成长期；成长 90 且有 3 个有效成长日成年。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("已解锁形态").font(.subheadline.weight(.semibold))
                            HStack(spacing: 6) {
                                ForEach(0..<4) { form in
                                    Button {
                                        store.evolve(form)
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(
                                                nsImage: CompanionArtwork.sprite(
                                                    family: pet.family, form: form)
                                            )
                                            .resizable().interpolation(.none).frame(width: 56, height: 56)
                                            Text(CompanionCatalog.forms[pet.family][form]).font(.caption)
                                            Image(
                                                systemName: !pet.unlockedForms.contains(form)
                                                    ? "lock.fill"
                                                    : pet.form == form ? "checkmark.circle.fill" : "circle"
                                            )
                                            .font(.caption).foregroundStyle(.secondary)
                                        }.frame(maxWidth: .infinity)
                                    }.buttonStyle(.plain).disabled(
                                        !pet.unlockedForms.contains(form) || store.session != nil)
                                }
                            }
                            Button("查看训练、遗物与进化条件") {
                                store.openSettings("我的伙伴")
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            ForEach(store.archive.pets) { friend in
                                Button {
                                    store.select(friend.id)
                                } label: {
                                    HStack {
                                        CompanionPortrait(pet: friend).frame(width: 48, height: 48)
                                        VStack(alignment: .leading) {
                                            Text(friend.name).font(.subheadline.weight(.medium))
                                            Text("\(friend.familyTitle) · \(friend.stageTitle)").font(
                                                .caption
                                            ).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if friend.id == pet.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                                        }
                                    }.padding(8).background(
                                        .primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                                }.buttonStyle(.plain)
                            }
                            Button("孵化精灵蛋 · \(store.archive.eggs)", systemImage: "sparkles") { store.hatch() }
                                .buttonStyle(.bordered).disabled(store.archive.eggs == 0)
                        }
                        if let notice = store.notice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 2)
                }.scrollIndicators(.hidden)
                HStack {
                    Menu {
                        Button("让它玩贪吃蛇") {
                            store.startGame(.snake)
                            dismiss()
                        }.disabled(!store.isGameUnlocked(.snake))
                        Button("让它玩星灯航行") {
                            store.startGame(.flight)
                            dismiss()
                        }.disabled(!store.isGameUnlocked(.flight))
                        Button("训练与游戏设置") {
                            store.openSettings("小游戏")
                            dismiss()
                        }
                    } label: {
                        Label("让它玩", systemImage: "gamecontroller")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Button("回窝", systemImage: "house") {
                        store.nest()
                        dismiss()
                    }.buttonStyle(.bordered)
                }
            }
        }
        .padding(22)
        .nativeLiquidGlassSurface(
            level: 0.65, cornerRadius: 28,
            contentSize: CGSize(width: 390, height: 510), samplesDesktopBackdrop: true
        )
        .padding(12)
    }
    private func meter(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value))").monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            ProgressView(value: min(100, max(0, value)), total: 100).tint(color)
        }.frame(maxWidth: .infinity)
    }
    private func tile(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary)
            Text(title).font(.caption.weight(.medium))
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    private func care(_ title: String, _ symbol: String, _ action: String) -> some View {
        Button {
            store.care(action)
        } label: {
            tile(title, symbol)
        }.buttonStyle(.plain)
    }
}

@MainActor final class CompanionNestFeedback: ObservableObject {
    enum Phase { case none, near, entering, exiting }
    @Published var phase: Phase = .none
    @Published var progress = 0.0
    @Published var family = 0
    @Published var reduced = false
    // Authoritative desktop geometry comes from the notch window controller.
    var surfaceFrame: NSRect?
    var centerX: CGFloat?
    var entrance: NSPoint? {
        surfaceFrame.map { NSPoint(x: centerX ?? $0.midX, y: $0.minY) }
    }
    @Published var occupied = false
    func reset() {
        phase = .none
        progress = 0
    }
}

/// Kept in the real notch surface. Its observation is isolated from AppModel
/// and the archive so animation frames never trigger storage or panel layout.
struct CompanionNestPortal: View {
    @ObservedObject var feedback: CompanionNestFeedback
    var body: some View {
        let active = feedback.phase != .none
        let pulse = feedback.phase == .near || feedback.reduced ? 0.5 : sin(feedback.progress * .pi)
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color(nsColor: CompanionArtwork.palettes[feedback.family]).opacity(active ? 0.45 : 0))
                .frame(width: 34 + 24 * pulse, height: 2 + 2 * pulse)
                .shadow(
                    color: Color(nsColor: CompanionArtwork.palettes[feedback.family]).opacity(
                        active ? 0.55 : 0), radius: 5 + 3 * pulse)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor final class CompanionCareVisibility: ObservableObject {
    @Published var visible = false
}

struct CompanionNestControl: View {
    @ObservedObject var store: CompanionStore
    @ObservedObject var feedback: CompanionNestFeedback
    @State private var draggingOut = false
    var body: some View {
        ZStack {
            CompanionNestPortal(feedback: feedback)
            // Keep the gesture view alive after emerge() changes inNest.
            Group {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: CompanionArtwork.palettes[feedback.family]))
                    .frame(width: 54, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.dismissNestGuide()
                        store.emerge()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4).onChanged { _ in
                            guard store.preferences.enabled, store.preferences.inNest || draggingOut else {
                                return
                            }
                            if !draggingOut { store.dismissNestGuide() }
                            draggingOut = true
                            store.desktopDragHandler?(NSEvent.mouseLocation)
                        }.onEnded { _ in
                            if draggingOut { store.desktopDragHandler?(nil) }
                            draggingOut = false
                        }
                    )
                    .contextMenu {
                        Button("出来玩") {
                            store.dismissNestGuide()
                            store.emerge()
                        }
                        Button("怎么带它出来？") { store.requestNestGuide() }
                        Button("精灵小窝") { store.openSettings("精灵小窝") }
                    }
                    .help("点击出来玩，或按住向下拖出")
                    .accessibilityLabel("精灵小窝，点击让伙伴出来，也可向下拖出")
            }
            .opacity(store.preferences.enabled && (feedback.occupied || draggingOut) ? 1 : 0)
            .allowsHitTesting(store.preferences.enabled && (feedback.occupied || draggingOut))
        }
    }
}

struct CompanionNestGuide: View {
    @ObservedObject var store: CompanionStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("它已经回到小窝", systemImage: "pawprint.fill").font(.headline)
            Text("按住刘海底部的小爪印向下拖，就能带它出来。也可以直接点击小爪印。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("知道了") { store.dismissNestGuide() }.buttonStyle(.bordered)
                Spacer()
                Button("出来玩") {
                    store.dismissNestGuide()
                    store.emerge()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(18)
            .nativeLiquidGlassSurface(
                level: 0.65, cornerRadius: 22,
                contentSize: CGSize(width: 330, height: 155), samplesDesktopBackdrop: true
            )
            .padding(10)
    }
}
