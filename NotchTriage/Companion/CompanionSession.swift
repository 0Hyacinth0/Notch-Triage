import Foundation

struct CompanionPoint: Codable, Equatable, Hashable {
    var x: Double, y: Double
    func distance(_ p: Self) -> Double { hypot(x - p.x, y - p.y) }
}
struct CompanionEnemy: Codable, Identifiable {
    var id: UInt64, kind: Int, position: CompanionPoint, hp: Double, maxHP: Double
    var age = 0.0, shot = 0.0, phase = 0
    var boss: Bool { kind >= 5 }
}
struct CompanionBullet: Codable, Identifiable {
    var id: UInt64, position: CompanionPoint, velocity: CompanionPoint
    var damage: Double = 1, remaining = 1
    var hit: Set<UInt64> = []
    var threatened = false
    var evadeCounted = false
}
struct CompanionVolley: Codable {
    var due: Double, origin: CompanionPoint, angle: Double
}
struct CompanionParticle: Codable {
    var position: CompanionPoint, life: Double, size: Double, kind: Int
}

/// Simulation time is advanced only while visible and running. Rendering and
/// controller handoffs never advance or rebuild this state.
final class CompanionSession: Codable, Identifiable {
    let id: UUID, petID: UUID, game: CompanionGame
    let levels: [Int], permanent: [Int]
    let family: Int, form: Int, skin: Bool
    var random: UInt64
    var paused = false, manual = false, finished = false, settled = false
    var result = "", score = 0, time = 0.0
    var xp = [Int](repeating: 0, count: 4), counts: [String: Int] = [:]
    var temporary: [Int: Int] = [:], candidates: [Int] = [], pendingReplacement: Int?
    var pool: [Int]
    var charges = 0, recharge = 0.0, cooldown = 0.0
    var chargeBank = 0, chargeCapacitySeen = 0
    var volleys: [CompanionVolley] = []
    var slowUntil = 0.0, slowCooldown = 0.0
    var particles: [CompanionParticle] = []
    var snake = [CompanionPoint(x: 8, y: 10), .init(x: 7, y: 10), .init(x: 6, y: 10), .init(x: 5, y: 10)]
    var food: [CompanionPoint] = [], direction = 1, queue: [Int] = []
    var stepClock = 0.0, steps = 0, lastFoodStep = -100, riskStep = -100
    var shotEvents = 0
    var correctionUntil = 0.0
    var player = CompanionPoint(x: 50, y: 52), hp = 3, invulnerableUntil = 0.0
    var wave = 1, waveClock = 0.0, spawnClock = 0.0, fireClock = 0.0
    var enemies: [CompanionEnemy] = [], bullets: [CompanionBullet] = [], shots: [CompanionBullet] = []
    var supplies: [CompanionPoint] = [], hitSequence = 0
    var keys: Set<Int> = [], mouseTarget: CompanionPoint?
    var bossSpawned = false, bossEntrance = 0.0

    init(pet: UUID, game: CompanionGame, progress: CompanionProgress, family: Int = 0, form: Int = 0) {
        self.family = family
        self.form = form
        skin = progress.skin
        id = UUID()
        petID = pet
        self.game = game
        levels = (0..<4).map { progress.level($0) }
        permanent = progress.equipment
        random = UInt64.random(in: 1...UInt64.max)
        pool = Array(1...6)
        if game == .snake {
            if progress.totals["food", default: 0] >= 50 { pool.append(7) }
            if progress.totals["food", default: 0] >= 100 { pool.append(8) }
        } else {
            if progress.totals["wave", default: 0] >= 12 { pool.append(7) }
            if progress.totals["boss", default: 0] >= 3 { pool.append(8) }
        }
        charges = rank(game == .snake ? 1 : 2)
        chargeBank = charges
        chargeCapacitySeen = charges
        if game == .snake { addFood() }
    }
    func next(_ limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        random ^= random << 13
        random ^= random >> 7
        random ^= random << 17
        return Int(random % UInt64(limit))
    }
    func rank(_ number: Int) -> Int { permanent.contains(number) ? 1 : temporary[number, default: 0] }
    func count(_ key: String, _ amount: Int = 1) { counts[key, default: 0] += amount }
    func pause() {
        paused = true
        keys.removeAll()
        mouseTarget = nil
        particles.removeAll()
    }
    func resume() {
        guard candidates.isEmpty, !finished else { return }
        paused = false
    }
    func handoff(_ human: Bool) {
        manual = human
        keys.removeAll()
        mouseTarget = nil
    }
    func end(_ reason: String) {
        finished = true
        paused = true
        result = reason
        keys.removeAll()
        particles.removeAll()
    }
    func turn(_ value: Int) {
        let last = queue.last ?? direction
        if queue.count < 2 && value != last && (value + 2) % 4 != last { queue.append(value) }
    }
    func choose(_ item: Int, replacing: Int? = nil) {
        guard candidates.contains(item), !finished else { return }
        if temporary[item] == nil && temporary.count >= 6 {
            let replacement = replacing ?? (!manual ? temporary.min { $0.value < $1.value }?.key : nil)
            guard let replacing = replacement, temporary[replacing] != nil else {
                pendingReplacement = item
                return
            }
            temporary.removeValue(forKey: replacing)
            if replacing == (game == .snake ? 1 : 2) {
                chargeBank = charges
                charges = 0
            }
        }
        let old = rank(item)
        temporary[item] = min(3, old + 1)
        if item == (game == .snake ? 1 : 2) {
            let base = old == 0 ? chargeBank : charges
            charges = min(rank(item), base + max(0, rank(item) - chargeCapacitySeen))
            chargeCapacitySeen = max(chargeCapacitySeen, rank(item))
        }
        pendingReplacement = nil
        candidates.removeAll()
        paused = false
        burst(game == .snake ? snake[0] : player, kind: 3)
    }
    func chooseAutomatically() {
        guard !candidates.isEmpty, !manual else { return }
        let protection = game == .snake ? 1 : 2
        let chosen =
            candidates.contains(protection) && charges == 0
            ? protection : candidates.max { rank($0) < rank($1) }!
        choose(chosen)
    }
    func offer() {
        var valid = pool.filter { n in
            !permanent.contains(n) && rank(n) < 3
                && !(CompanionCatalog.relics(game)[n - 1].conflicts.map { rank($0) > 0 } ?? false)
        }
        candidates.removeAll()
        while !valid.isEmpty && candidates.count < 3 {
            let weights = valid.map { rank($0) > 0 ? 2 : 3 }
            var draw = next(weights.reduce(0, +))
            var index = 0
            while draw >= weights[index] {
                draw -= weights[index]
                index += 1
            }
            candidates.append(valid.remove(at: index))
        }
        if candidates.isEmpty {
            if game == .snake { score += 20 } else if hp < 3 { hp += 1 } else { score += 50 }
        } else {
            paused = true
            if !manual {
                // Favor protection when vulnerable, then improvements already
                // held; ties consume saved RNG rather than window state.
                chooseAutomatically()
            }
        }
    }
    func burst(_ point: CompanionPoint, kind: Int, size: Double = 1) {
        particles.append(.init(position: point, life: 0.45, size: size, kind: kind))
        if particles.count > 200 { particles.removeFirst(particles.count - 200) }
    }
    func update(_ dt: Double) {
        guard !paused, !finished else { return }
        let dt = min(0.05, max(0, dt))
        time += dt
        for i in particles.indices { particles[i].life -= dt }
        particles.removeAll { $0.life <= 0 }
        if game == .snake { updateSnake(dt) } else { updateFlight(dt) }
    }
    private var vectors: [CompanionPoint] {
        [CompanionPoint(x: 0, y: -1), .init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: -1, y: 0)]
    }
    func nextHead(_ dir: Int) -> CompanionPoint {
        .init(x: snake[0].x + vectors[dir].x, y: snake[0].y + vectors[dir].y)
    }
    func legal(_ point: CompanionPoint) -> Bool {
        guard point.x >= 0, point.x < 30, point.y >= 0, point.y < 20 else { return false }
        return !snake.prefix(snake.count - (food.contains(point) ? 0 : 1)).contains(point)
    }
    func addFood() {
        let free = (0..<600).map { CompanionPoint(x: Double($0 % 30), y: Double($0 / 30)) }.filter {
            !snake.contains($0) && !food.contains($0)
        }
        guard !free.isEmpty else {
            if food.isEmpty { end("满盘完成") }
            return
        }
        food.append(free[next(free.count)])
    }
    func snakeDirection() -> Int {
        let options = (0..<4).filter { ($0 + 2) % 4 != direction && legal(nextHead($0)) }
        let occupied = Set(snake.dropLast())
        let depth = min(24, levels[0] + 2 + rank(6) * 2)
        func evaluate(_ start: CompanionPoint) -> Double {
            var visited: Set<CompanionPoint> = [start]
            var frontier = [start]
            var reachable = 0
            var tailReachable = false
            let tail = snake.last!
            for layer in 0..<max(depth, levels[1] + 3) {
                var nextLayer: [CompanionPoint] = []
                for p in frontier {
                    for v in vectors {
                        let q = CompanionPoint(x: p.x + v.x, y: p.y + v.y)
                        if q.x >= 0 && q.x < 30 && q.y >= 0 && q.y < 20 && !occupied.contains(q)
                            && visited.insert(q).inserted
                        {
                            nextLayer.append(q)
                        }
                    }
                }
                if layer < depth { reachable += nextLayer.count }
                if layer < levels[1] + 3 && nextLayer.contains(tail) { tailReachable = true }
                frontier = nextLayer
                if frontier.isEmpty { break }
            }
            let distance = food.map { abs(start.x - $0.x) + abs(start.y - $0.y) }.min() ?? 0
            let tailDistance = abs(start.x - tail.x) + abs(start.y - tail.y)
            return Double(reachable) * (reachable < snake.count ? 4 : 0.12) - distance - tailDistance
                / Double(levels[1] + 3) + (tailReachable ? 8 : 0)
        }
        return options.max { evaluate(nextHead($0)) < evaluate(nextHead($1)) } ?? direction
    }
    func updateSnake(_ dt: Double) {
        if correctionUntil > 0 {
            if manual && queue.isEmpty {
                if time >= correctionUntil { end("未能及时调整方向") }
                return
            }
            correctionUntil = 0
        }
        stepClock += dt
        let interval =
            max(0.1, 0.22 - Double(counts["food", default: 0] / 5) * 0.01) / (time < slowUntil ? 0.8 : 1)
        guard stepClock >= interval else { return }
        stepClock -= interval
        let oldDir = direction
        if !manual { direction = snakeDirection() } else if !queue.isEmpty { direction = queue.removeFirst() }
        if oldDir != direction { count("turn") }
        let head = nextHead(direction)
        guard legal(head) else {
            if rank(1) > 0 && charges > 0
                && (0..<4).contains(where: { ($0 + 2) % 4 != direction && legal(nextHead($0)) })
            {
                charges -= 1
                xp[3] += 4
                queue.removeAll()
                correctionUntil = time + 0.75
                stepClock = 0
                lastFoodStep = -100
                burst(snake[0], kind: 3)
            } else {
                end("下次再试")
            }
            return
        }
        let blocked = (0..<4).filter { !legal(nextHead($0)) }.count
        steps += 1
        snake.insert(head, at: 0)
        if let index = food.firstIndex(of: head) {
            food.remove(at: index)
            count("food")
            xp[0] += 2
            let n = counts["food", default: 0]
            score += 10 + rank(2)
            if steps - lastFoodStep <= 25 { score += rank(5) * 2 }
            lastFoodStep = steps
            if time < slowUntil { xp[2] += 3 }
            if rank(1) > 0 {
                recharge += 1
                if recharge >= Double(52 - levels[3] * 2) {
                    charges = min(rank(1), charges + 1)
                    recharge = 0
                }
            }
            if rank(4) > 0 && n % (9 - rank(4)) == 0 {
                slowUntil = time + min(12, Double(4 + rank(4) * 2) + Double(levels[2] - 1) * 0.1)
            }
            if rank(7) > 0 && n % (14 - rank(7) * 2) == 0 { score += 30 }
            if rank(8) > 0 && n % (12 - rank(8) * 2) == 0 && snake.count > 4 { snake.removeLast() }
            if food.isEmpty { addFood() }
            if rank(3) > 0 && n % (12 - rank(3) * 2) == 0 && food.count < 2 {
                if snake.count + food.count < 600 { addFood() } else { score += 10 }
            }
            burst(head, kind: 0)
            if !finished && n % 5 == 0 { offer() }
        } else {
            snake.removeLast()
        }
        if !finished && blocked >= 2 && (0..<4).filter({ !legal(nextHead($0)) }).count < 2
            && steps - riskStep >= 4
        {
            xp[1] += 1
            riskStep = steps
        }
    }
    func spawnEnemy() {
        guard enemies.count < 40 else { return }
        let elite = wave % 6 == 3
        let weights = elite ? [20, 25, 35, 20] : [50, 25, 10, 15]
        var r = next(100)
        var kind = 1
        for (i, w) in weights.enumerated() {
            if r < w {
                kind = i + 1
                break
            }
            r -= w
        }
        let n = kind == 4 ? 2 : 1
        guard enemies.count + n <= 40 else { return }
        let x = Double(10 + next(80))
        let base = [24.0, 40, 100, 20][kind - 1] * min(2.2, 1 + Double(wave - 1) * 0.04)
        for j in 0..<n {
            var enemy = CompanionEnemy(
                id: randomID(), kind: kind, position: .init(x: x + Double(j) * 6, y: -2), hp: base,
                maxHP: base)
            enemy.shot = [2.4, 3, 3.5, 3][kind - 1] - 1.2 - Double(j) * 0.3
            enemies.append(enemy)
        }
    }
    func randomID() -> UInt64 {
        _ = next(Int.max)
        return random
    }
    func enemyShot(_ position: CompanionPoint, angle: Double) {
        guard bullets.count < 180 else { return }
        let speed = min(18, 10 + Double(wave - 1) * 0.3)
        bullets.append(
            .init(
                id: randomID(), position: position,
                velocity: .init(x: sin(angle) * speed, y: cos(angle) * speed)))
    }
    func aim(_ from: CompanionPoint) -> Double { atan2(player.x - from.x, player.y - from.y) }
    func fan(_ from: CompanionPoint, n: Int, spacing: Double, offset: Double = 0) {
        for i in 0..<n {
            enemyShot(from, angle: aim(from) + (Double(i) - Double(n - 1) / 2) * spacing * .pi / 180 + offset)
        }
    }
    func completeWave() {
        count("wave")
        if rank(7) > 0 && counts["wave", default: 0] % (7 - rank(7)) == 0 { hp = min(3, hp + 1) }
        let reward = wave % 3 == 0
        wave += 1
        waveClock = 0
        spawnClock = 0
        bossSpawned = false
        if reward { offer() }
    }
    func updateFlight(_ dt: Double) {
        waveClock += dt
        fireClock += dt
        let slow = time < slowUntil ? 0.7 : 1.0
        if rank(2) > 0 {
            recharge += dt
            if recharge >= Double(92 - levels[3] * 2) {
                recharge = 0
                charges = min(rank(2), charges + 1)
            }
        }
        var movement = CompanionPoint(x: 0, y: 0)
        if manual {
            movement.x = Double((keys.contains(1) ? 1 : 0) - (keys.contains(3) ? 1 : 0))
            movement.y = Double((keys.contains(2) ? 1 : 0) - (keys.contains(0) ? 1 : 0))
            if let mouseTarget { movement = .init(x: mouseTarget.x - player.x, y: mouseTarget.y - player.y) }
        } else {
            let horizon = 0.20 + Double(levels[1]) * 0.05
            if let threat = bullets.min(by: { $0.position.distance(player) < $1.position.distance(player) }),
                threat.position.distance(player) < 12
            {
                let future = CompanionPoint(
                    x: threat.position.x + threat.velocity.x * horizon,
                    y: threat.position.y + threat.velocity.y * horizon)
                movement = .init(x: player.x - future.x, y: player.y - future.y)
            } else if let supply = supplies.min(by: { $0.distance(player) < $1.distance(player) }), hp < 3 {
                movement = .init(x: supply.x - player.x, y: supply.y - player.y)
            } else if let target = enemies.min(by: {
                $0.position.distance(player) < $1.position.distance(player)
            }) {
                let lead = Double(levels[0] - 1) * 0.1
                let velocityX =
                    target.kind == 2
                    ? cos(target.age * .pi / 2) * 6 * .pi / 2
                    : target.kind == 4
                        ? cos(target.age * 2 * .pi / 5) * 8 * 2 * .pi / 5
                        : target.kind == 5 && target.phase > 0 ? cos(target.age * .pi / 3) * 15 * .pi / 3 : 0
                movement = .init(x: target.position.x + velocityX * lead - player.x, y: 52 - player.y)
            }
        }
        let length = hypot(movement.x, movement.y)
        let speed = 28 * (1 + Double(rank(3)) * 0.08)
        if length > 0 {
            let distance = min(length, speed * dt)
            player.x += movement.x / length * distance
            player.y += movement.y / length * distance
        }
        player.x = min(99, max(1, player.x))
        player.y = min(59, max(1, player.y))
        if fireClock >= 0.18 && shots.count + 1 + rank(1) * 2 <= 96 {
            fireClock = 0
            shotEvents += 1
            let mult = 1 + Double(levels[2] - 1) * 0.01
            for side in -rank(1)...rank(1) {
                shots.append(
                    .init(
                        id: randomID(), position: player, velocity: .init(x: Double(side) * 7, y: -80),
                        damage: (side == 0 ? 10 : 4) * mult, remaining: 1 + rank(4)))
            }
        }
        if wave % 6 == 0 {
            if !bossSpawned {
                enemies.removeAll()
                bullets.removeAll()
                volleys.removeAll()
                bossSpawned = true
                bossEntrance = time + 1.5
                let kind = 5 + ((wave / 6 - 1) % 3)
                let base = Double([1000, 1200, 1400][kind - 5]) * min(2.2, 1 + Double(wave - 1) * 0.04)
                enemies.append(
                    .init(id: randomID(), kind: kind, position: .init(x: 50, y: 12), hp: base, maxHP: base))
            }
        } else {
            spawnClock += dt
            if spawnClock >= max(0.45, 1.2 - Double(wave - 1) * 0.04) {
                spawnClock = 0
                spawnEnemy()
            }
            if waveClock >= 30 {
                completeWave()
                if paused { return }
            }
        }
        for volley in volleys where volley.due <= time { enemyShot(volley.origin, angle: volley.angle) }
        volleys.removeAll { $0.due <= time }
        for i in enemies.indices {
            var e = enemies[i]
            e.age += dt * slow
            e.shot += dt * slow
            if e.boss {
                let phase = e.hp / e.maxHP < 0.3 ? 2 : e.hp / e.maxHP < 0.6 ? 1 : 0
                if phase > e.phase {
                    e.phase = phase
                    e.shot = -0.8
                }
                if e.kind == 5 && e.phase > 0 { e.position.x = 50 + sin(e.age * .pi / 3) * 15 }
                let interval = [2.4, 3.2, 3.6][e.kind - 5]
                if time >= bossEntrance && e.shot >= interval && bullets.count <= 160 {
                    e.shot = 0
                    if e.kind == 5 {
                        fan(e.position, n: 5, spacing: 15)
                        if e.phase == 2 {
                            for j in 0..<5 {
                                volleys.append(
                                    .init(
                                        due: time + 0.8, origin: e.position,
                                        angle: aim(e.position) + Double(j - 2) * .pi / 12 + .pi / 12))
                            }
                        }
                    } else if e.kind == 6 {
                        let gap = e.phase > 0 ? Int(e.age / interval) % 16 : 0
                        for j in 0..<16 where (j - gap + 16) % 16 >= 3 {
                            enemyShot(e.position, angle: Double(j) * .pi / 8)
                        }
                        if e.phase == 2 {
                            volleys.append(.init(due: time + 1, origin: e.position, angle: aim(e.position)))
                        }
                    } else {
                        var origin = e.position
                        if e.phase > 0 { origin.x += Int(e.age / interval) % 2 == 0 ? -8 : 8 }
                        let angle = aim(origin)
                        for j in 0..<3 {
                            volleys.append(.init(due: time + Double(j) * 0.15, origin: origin, angle: angle))
                        }
                        if e.phase == 2 {
                            origin.x = 100 - origin.x
                            for j in 0..<3 {
                                volleys.append(
                                    .init(
                                        due: time + 0.8 + Double(j) * 0.15, origin: origin, angle: aim(origin)
                                    ))
                            }
                        }
                    }
                }
            } else {
                e.position.y += [6.0, 4, 2.5, 4][e.kind - 1] * dt * slow
                if e.kind == 2 { e.position.x += cos(e.age * .pi / 2) * 6 * .pi / 2 * dt * slow }
                if e.kind == 4 { e.position.x += cos(e.age * 2 * .pi / 5) * 8 * 2 * .pi / 5 * dt * slow }
                let interval = [2.4, 3, 3.5, 3][e.kind - 1]
                if e.age >= 1.2 && e.shot >= interval {
                    e.shot = 0
                    fan(e.position, n: e.kind == 2 ? 3 : e.kind == 3 ? 5 : 1, spacing: e.kind == 2 ? 20 : 15)
                }
            }
            enemies[i] = e
        }
        for i in shots.indices {
            shots[i].position.x += shots[i].velocity.x * dt
            shots[i].position.y += shots[i].velocity.y * dt
        }
        for i in bullets.indices {
            bullets[i].position.x += bullets[i].velocity.x * dt * slow
            bullets[i].position.y += bullets[i].velocity.y * dt * slow
            if bullets[i].position.distance(player) < 2.15 && !bullets[i].evadeCounted {
                bullets[i].threatened = true
            }
            if bullets[i].position.distance(player) < 0.65 + 0.25 && time >= invulnerableUntil {
                damage(1)
                bullets[i].remaining = 0
                bullets[i].threatened = false
            } else if bullets[i].threatened && bullets[i].position.distance(player) > 3
                && bullets[i].remaining > 0
            {
                if !bullets[i].evadeCounted {
                    bullets[i].evadeCounted = true
                    xp[1] += 1
                    count("evade")
                    if rank(8) > 0 && counts["evade", default: 0] % (9 - rank(8)) == 0 && time >= slowCooldown
                    {
                        slowUntil = time + 2 + Double(rank(8)) * 0.5
                        slowCooldown = time + 20
                    }
                }
                bullets[i].threatened = false
            }
        }
        for i in shots.indices {
            for j in enemies.indices where enemies[j].hp > 0 {
                let radius = enemies[j].boss ? 6.0 : 1.25
                if shots[i].remaining > 0 && !shots[i].hit.contains(enemies[j].id)
                    && shots[i].position.distance(enemies[j].position) <= radius + 0.2
                {
                    burst(enemies[j].position, kind: 1, size: 0.3)
                    enemies[j].hp -= shots[i].damage
                    shots[i].hit.insert(enemies[j].id)
                    shots[i].remaining -= 1
                    hitSequence += 1
                    if hitSequence >= 5 {
                        hitSequence -= 5
                        xp[0] += 2
                    }
                }
            }
        }
        var dead = enemies.filter { $0.hp <= 0 }
        var processed: Set<UInt64> = []
        for e in dead { processed.insert(e.id) }
        if rank(5) > 0 {
            for e in dead {
                let blast = Double(12 + rank(5) * 8)
                let radius = 1.5 + Double(rank(5)) * 0.5
                for i in enemies.indices
                where enemies[i].hp > 0 && enemies[i].position.distance(e.position) <= radius {
                    enemies[i].hp -= blast
                }
            }
            // Explosion deaths are counted but never recursively emit blasts.
            dead += enemies.filter { $0.hp <= 0 && !processed.contains($0.id) }
        }
        var bossDied = false
        for e in dead {
            count("kill")
            if e.kind == 3 { count("armor") }
            xp[2] += e.boss ? 10 : 2
            score += e.boss ? [500, 650, 800][e.kind - 5] : [20, 35, 70, 25][e.kind - 1]
            if e.boss {
                count("boss")
                if e.kind == 7 { count("boss3") }
                bossDied = true
                volleys.removeAll()
            }
            if e.boss || next(100) < 8 { supplies.append(e.position) }
            burst(e.position, kind: 1, size: e.boss ? 6 : 1.5)
        }
        enemies.removeAll { $0.hp <= 0 || $0.position.y > 64 }
        for e in enemies where e.position.distance(player) < (e.boss ? 6.65 : 1.9) { damage(e.boss ? 2 : 1) }
        let pickup = rank(6) > 0 ? Double(rank(6) + 1) : 1
        for p in supplies where p.distance(player) <= pickup {
            if hp < 3 { hp += 1 } else { score += 10 }
            count("supply")
            burst(p, kind: 0)
        }
        supplies.removeAll { $0.distance(player) <= pickup }
        for i in supplies.indices { supplies[i].y += 4 * dt }
        supplies.removeAll { $0.y > 65 }
        shots.removeAll {
            $0.remaining <= 0 || $0.position.y < -5 || $0.position.x < -5 || $0.position.x > 105
        }
        bullets.removeAll {
            $0.remaining <= 0 || $0.position.y > 65 || $0.position.y < -5 || $0.position.x < -5
                || $0.position.x > 105
        }
        if hp <= 0 { end("谢谢你陪它飞这一程") } else if bossDied { completeWave() }
    }
    func damage(_ amount: Int) {
        guard time >= invulnerableUntil else { return }
        if rank(2) > 0 && charges > 0 {
            charges -= 1
            xp[3] += 4
            burst(player, kind: 3)
        } else {
            hp -= amount
            burst(player, kind: 2)
        }
        invulnerableUntil = time + 1
    }
}
