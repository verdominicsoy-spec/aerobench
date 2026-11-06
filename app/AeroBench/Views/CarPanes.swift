import AeroBenchKit
import SwiftUI

/// Wing Lab's car: the base car from its STEP, and front and rear wing cards
/// placed on it inside the car's rules boxes. The car is not solved: the
/// wings' numbers are Wing Lab's own.
// MARK: Base car

struct BaseCarPane: View {
    @Environment(AppState.self) private var app
    var embedded = false  // in Wing Lab's inspector: its section header is the title, no pane

    var body: some View {
        @Bindable var car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            if !embedded { Text("Base car").font(.system(size: 20, weight: .semibold)) }
            HStack {
                Button(car.setup == nil ? "Choose STEP…" : "Change STEP…") { app.chooseCarSTEP() }
                if let s = car.setup { Text(URL(fileURLWithPath: s.step).lastPathComponent).lineLimit(1).foregroundStyle(S37.C.inkSecondary) }
                if let j = car.setupJob, !j.status.isFinished { ProgressView().controlSize(.small) }
            }
            if let status = car.status { Text(status).font(.caption).foregroundStyle(S37.C.clayInk) }
            if let s = car.setup {
                ForEach(Array(s.wheels.enumerated()), id: \.element.name) { i, w in
                    HStack {
                        Text(w.name).frame(width: 28, alignment: .leading)
                        NumberField(label: "x", unit: "mm", digits: 0, value: wheelBinding(i, \.centre[0]))
                        NumberField(label: "r", unit: "mm", digits: 0, value: wheelBinding(i, \.radius))
                    }
                }
                NumberField(label: "Ground", unit: "mm", digits: 0, value: setupBinding(\.groundZ))
                HStack {
                    Toggle("Mark head restraint", isOn: $car.markingHeadRestraint).toggleStyle(.button)
                    if let h = s.headRestraint { Text(String(format: "x %.0f, z %.0f mm", h[0], h[1])).font(.caption) }
                }
                NumberField(label: "Car speed", unit: "m/s", digits: 1, value: Binding(get: { app.car.setup?.speed ?? 15 }, set: { v in
                    app.car.setup?.speed = v
                    app.setupChanged()
                }))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carPane(embedded)
    }

    private func setupBinding(_ key: WritableKeyPath<CarSetup, Double>) -> Binding<Double> {
        Binding(get: { app.car.setup?[keyPath: key] ?? 0 }, set: { v in app.car.setup?[keyPath: key] = v; app.setupChanged() })
    }

    private func wheelBinding(_ i: Int, _ key: WritableKeyPath<CarSetup.Wheel, Double>) -> Binding<Double> {
        Binding(get: { app.car.setup?.wheels[i][keyPath: key] ?? 0 },
                set: { v in app.car.setup?.wheels[i][keyPath: key] = v; app.setupChanged() })
    }
}

// MARK: Drawing

/// Car (x forward, z up, mm) to view points, the nose on the left.
struct CarFrame {
    var minX: Double, maxX: Double, minZ: Double, maxZ: Double
    var size: CGSize
    var pad: CGFloat = 16

    var scale: Double {
        min((size.width - 2 * pad) / max(maxX - minX, 1), (size.height - 2 * pad) / max(maxZ - minZ, 1))
    }

    func point(_ x: Double, _ z: Double) -> CGPoint {
        CGPoint(x: pad + (maxX - x) * scale, y: pad + (maxZ - z) * scale)
    }

    func car(_ p: CGPoint) -> (x: Double, z: Double) {
        (maxX - (p.x - pad) / scale, maxZ - (p.y - pad) / scale)
    }
}

private func outlinePath(_ points: [[Double]], _ f: CarFrame) -> Path {
    var path = Path()
    for (k, p) in points.enumerated() where p.count == 2 {
        let q = f.point(p[0], p[1])
        if k == 0 { path.move(to: q) } else { path.addLine(to: q) }
    }
    path.closeSubpath()
    return path
}

// MARK: Side view

struct SideViewPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var dragging: WingPosition?
    @State private var startPlacement: Placement?
    @State private var clampNote: String?

    var body: some View {
        let car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text("Side view").font(.system(size: 20, weight: .semibold))
            GeometryReader { geo in
                let f = frame(geo.size)
                Canvas { ctx, _ in draw(ctx, f) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in drag(g, f) }
                        .onEnded { g in endDrag(g, f) })
            }
            .frame(height: 300)
            if let combo = app.shownCombo {
                placementFields(combo, .front)
                placementFields(combo, .rear)
                if let clampNote { Text(clampNote).font(.caption).foregroundStyle(S37.C.ochre) }
            } else {
                Text("Select or add a combination to place wings on the car.").font(.caption).foregroundStyle(S37.C.inkSecondary)
            }
        }
        .s37Pane()
    }

    private func frame(_ size: CGSize) -> CarFrame {
        let car = app.car
        let pts = (car.centreline?.loops ?? []).flatMap(\.points) + (car.setup?.wheels ?? []).flatMap { w in
            [[w.centre[0] - w.radius, w.centre[2] - w.radius], [w.centre[0] + w.radius, w.centre[2] + w.radius]]
        }
        var minX = pts.map { $0[0] }.min() ?? -2500, maxX = pts.map { $0[0] }.max() ?? 500
        var minZ = pts.map { $0[1] }.min() ?? -50, maxZ = pts.map { $0[1] }.max() ?? 1100
        if let s = car.setup {
            for p in [WingPosition.front, .rear] {
                let b = CarRules.box(p, setup: s)
                minX = min(minX, b.minX); maxX = max(maxX, b.maxX); minZ = min(minZ, s.groundZ); maxZ = max(maxZ, b.maxZ)
            }
        }
        return CarFrame(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, size: size)
    }

    private func draw(_ ctx: GraphicsContext, _ f: CarFrame) {
        let car = app.car
        guard let s = car.setup else { return }
        var ground = Path()
        ground.move(to: f.point(f.maxX, s.groundZ))
        ground.addLine(to: f.point(f.minX, s.groundZ))
        ctx.stroke(ground, with: .color(S37.C.inkTertiary), lineWidth: 1)
        for lp in car.centreline?.loops ?? [] {
            ctx.fill(outlinePath(lp.points, f), with: .color(S37.C.inkTertiary.opacity(0.25)))
            ctx.stroke(outlinePath(lp.points, f), with: .color(S37.C.inkSecondary), lineWidth: 0.8)
        }
        for w in s.wheels where w.name.hasSuffix("L") {
            let c = f.point(w.centre[0], w.centre[2]), r = w.radius * f.scale
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(S37.C.ink), lineWidth: 1.2)
        }
        if let h = s.headRestraint {
            let p = f.point(h[0], h[1])
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(S37.C.ochre))
        }
        for pos in [WingPosition.front, .rear] {
            let b = CarRules.box(pos, setup: s)
            let r = CGRect(origin: f.point(b.maxX, b.maxZ), size: .zero).union(CGRect(origin: f.point(b.minX, b.minZ), size: .zero))
            ctx.stroke(Path(r), with: .color(S37.C.chart6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        // The rear zone's T8.2.2 width bands: where each one starts, and how wide a wing may be in it
        let rear = CarRules.box(.rear, setup: s)
        for band in CarRules.widthBands(s) {
            let a = f.point(rear.minX, band.minZ), b = f.point(rear.maxX, band.minZ)
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            ctx.stroke(line, with: .color(S37.C.chart6.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
            let mid = f.point((rear.minX + rear.maxX) / 2, (band.minZ + band.maxZ) / 2)
            ctx.draw(Text("≤ \(Int(band.maxSpan.rounded())) mm wide").font(.system(size: 10, weight: .medium)).foregroundStyle(S37.C.chart6), at: mid)
        }
        guard let combo = app.shownCombo else { return }
        for (pos, p) in [(WingPosition.front, combo.front), (.rear, combo.rear)] {
            guard let p, let c = card(p.card) else { continue }
            let editing = app.carDraft?.position == pos  // the wing Wing Lab is editing
            for el in p.placedElements(card: c, setup: s) {
                let path = outlinePath(el.map { [$0.x, $0.y] }, f)
                ctx.fill(path, with: .color(editing ? S37.C.sage.opacity(0.8) : S37.C.sage.opacity(0.35)))
                ctx.stroke(path, with: .color(S37.C.sageInk), lineWidth: editing ? 1.5 : 1)
            }
        }
    }

    private func card(_ id: String) -> WingCard? { app.shownCards.first { $0.id == id } }

    private func isDraft(_ pos: WingPosition) -> Bool { app.carDraft?.position == pos }

    private func hit(_ point: CGPoint, _ f: CarFrame) -> WingPosition? {
        let car = app.car
        guard let s = car.setup, let combo = app.shownCombo else { return nil }
        let (x, z) = f.car(point)
        for (pos, p) in [(WingPosition.front, combo.front), (.rear, combo.rear)] {
            guard let p, let c = card(p.card) else { continue }
            let pts = p.placedElements(card: c, setup: s).flatMap { $0 }
            if let lo = pts.map(\.x).min(), let hi = pts.map(\.x).max(), let b = pts.map(\.y).min(), let t = pts.map(\.y).max(),
               x >= lo - 20, x <= hi + 20, z >= b - 20, z <= t + 20 { return pos }
        }
        return nil
    }

    private func drag(_ g: DragGesture.Value, _ f: CarFrame) {
        let car = app.car
        if car.markingHeadRestraint {
            let (x, z) = f.car(g.location)
            car.setup?.headRestraint = [x, z]
            return
        }
        if dragging == nil {
            dragging = hit(g.startLocation, f)
            if let pos = dragging, let combo = app.shownCombo {
                startPlacement = pos == .front ? combo.front : combo.rear
                if isDraft(pos) { app.wingLab.beginGesture("Move Wing on Car") }  // the height is Wing Lab's: one undo step for the drag
            }
        }
        guard let pos = dragging, var p = startPlacement, let c = card(p.card), let s = car.setup else { return }
        p.x -= Double(g.translation.width) / f.scale
        p.height -= Double(g.translation.height) / f.scale
        if isDraft(pos) {
            app.moveDraft(to: p.clamped(card: c, setup: s).0, live: true)
        } else {
            set(pos, p.clamped(card: c, setup: s).0, undoable: false)
        }
    }

    private func endDrag(_ g: DragGesture.Value, _ f: CarFrame) {
        let car = app.car
        if car.markingHeadRestraint {
            car.markingHeadRestraint = false
            // The rear box's forward limit moved: rear wings must still sit inside it.
            if let s = car.setup {
                for i in car.combos.indices {
                    if let p = car.combos[i].rear, let c = car.card(p.card) { car.combos[i].rear = p.clamped(card: c, setup: s).0 }
                }
            }
            app.setupChanged()
            return
        }
        if let pos = dragging, isDraft(pos), let combo = app.shownCombo, let now = pos == .front ? combo.front : combo.rear {
            app.moveDraft(to: now, live: false)
        } else if let pos = dragging, let before = startPlacement, let combo = car.selectedCombo,
           let now = pos == .front ? combo.front : combo.rear {
            set(pos, before, undoable: false)
            set(pos, now, undoable: true)
        }
        dragging = nil
        startPlacement = nil
    }

    private func set(_ pos: WingPosition, _ p: Placement?, undoable: Bool) {
        let car = app.car
        guard let i = car.combos.firstIndex(where: { $0.id == car.selected }) else { return }
        let old = car.combos
        if pos == .front { car.combos[i].front = p } else { car.combos[i].rear = p }
        guard undoable else { return }
        undo?.registerUndo(withTarget: car) { model in MainActor.assumeIsolated { model.combos = old } }
        undo?.setActionName("Move \(pos == .front ? "Front" : "Rear") Wing")
        app.saveCar()
    }

    private func typed(_ pos: WingPosition, _ q: Placement, _ c: WingCard, _ s: CarSetup) {
        let (fixed, moved) = q.clamped(card: c, setup: s)
        if !CarRules.fits(c, setup: s) {
            clampNote = "\(c.name) is bigger than its rules box: it cannot fit wherever it goes"
        } else {
            clampNote = moved ? "Kept inside the \(pos == .front ? "front" : "rear") wing's rules box" : nil
        }
        if isDraft(pos) { app.moveDraft(to: fixed, live: false) } else { set(pos, fixed, undoable: true) }
    }

    @ViewBuilder private func placementFields(_ combo: Combination, _ pos: WingPosition) -> some View {
        if let p = pos == .front ? combo.front : combo.rear, let c = card(p.card), let s = app.car.setup {
            HStack {
                Text("\(pos == .front ? "Front" : "Rear"): \(c.name)" + (isDraft(pos) ? " (editing)" : "")).frame(width: 140, alignment: .leading)
                NumberField(label: "ahead of axle", unit: "mm", digits: 0, value: Binding(get: { p.x }, set: { v in
                    var q = p; q.x = v; typed(pos, q, c, s) }))
                NumberField(label: "above ground", unit: "mm", digits: 0, value: Binding(get: { p.height }, set: { v in
                    var q = p; q.height = v; typed(pos, q, c, s) }))
            }
        }
    }
}

// MARK: Section

struct SectionPane: View {
    @Environment(AppState.self) private var app
    var embedded = false  // in Wing Lab's inspector: its section header is the title, no pane

    var body: some View {
        @Bindable var car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            HStack {
                if !embedded { Text("Section").font(.system(size: 20, weight: .semibold)) }
                Spacer()
                Text(String(format: "y %.0f mm", car.sectionY)).monospacedDigit().foregroundStyle(S37.C.inkSecondary)
            }
            Slider(value: $car.sectionY, in: 0...car.halfWidth) { editing in if !editing { app.refreshSections() } }
            GeometryReader { geo in
                Canvas { ctx, size in
                    guard let sec = car.section else { return }
                    let pts = sec.loops.flatMap(\.points)
                    guard !pts.isEmpty else { return }
                    let f = CarFrame(minX: pts.map { $0[0] }.min()!, maxX: pts.map { $0[0] }.max()!,
                                     minZ: pts.map { $0[1] }.min()!, maxZ: pts.map { $0[1] }.max()!, size: size)
                    for lp in sec.loops {
                        let path = outlinePath(lp.points, f)
                        ctx.stroke(path, with: .color(lp.kind == "wheel" ? S37.C.sageInk : S37.C.ink), lineWidth: 1)
                    }
                    for p in sec.open where p.count == 2 {
                        let q = f.point(p[0], p[1])
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(S37.C.clay))
                    }
                }
            }
            .frame(height: 220)
            if car.section?.loops.isEmpty ?? false {
                Text("The plane misses the car here.").font(.caption).foregroundStyle(S37.C.inkSecondary)
            }
        }
        .carPane(embedded)
    }
}

// MARK: Cards

struct CardsPane: View {
    @Environment(AppState.self) private var app
    var embedded = false  // in Wing Lab's library sidebar
    var open: ((WingCard) -> Void)?
    @Environment(\.undoManager) private var undo

    var body: some View {
        let car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            if !embedded { Text("Wing cards").font(.system(size: 20, weight: .semibold)) }
            if car.cards.isEmpty {
                Text("Save a wing as a card in the inspector's Lap Sim section.").font(.caption).foregroundStyle(S37.C.inkSecondary)
            }
            ForEach(car.cards) { c in
                CardRow(card: c, put: { assign(c) }, open: open.map { f in { f(c) } })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carPane(embedded)
    }

    private func assign(_ c: WingCard) {
        let car = app.car
        guard let i = car.combos.firstIndex(where: { $0.id == car.selected }), let s = car.setup else { return }
        let old = car.combos
        undo?.registerUndo(withTarget: car) { model in MainActor.assumeIsolated { model.combos = old } }
        undo?.setActionName("Put \(c.name) on the Car")
        let placed = Placement.start(card: c, setup: s)
        if c.position == .front { car.combos[i].front = placed } else { car.combos[i].rear = placed }
        app.saveCar()
    }
}

struct CardRow: View {
    @Environment(AppState.self) private var app
    let card: WingCard
    let put: () -> Void
    var open: (() -> Void)?

    var body: some View {
        let car = app.car
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("Name", text: nameBinding).textFieldStyle(.plain).font(.system(size: 16, weight: .semibold))
                Text(card.position == .front ? "Front" : "Rear").font(.caption).foregroundStyle(S37.C.inkSecondary)
                Spacer()
                if let open { Button("Open", action: open).help("Edit this card's wing") }
                Button("Put on Car", action: put).disabled(car.selectedCombo == nil || car.setup == nil)
            }
            Text(String(format: "2D −Cl %.3f   Cd %.4f on its chord   ", -card.section.cl, card.section.cd) + card.solver)
                .font(.caption).monospacedDigit()
            if let note = speedNote {
                Text(note).font(.caption).foregroundStyle(S37.C.ochre)
            }
        }
        .padding(S37.Space.s3)
        .background(RoundedRectangle(cornerRadius: S37.Radius.lgIn, style: .continuous).fill(S37.C.inset))
    }

    private var speedNote: String? {
        guard let s = app.car.setup, abs(card.speed - s.speed) > 0.01 else { return nil }
        return String(format: "Made at %.1f m/s; the car runs at %.1f", card.speed, s.speed)
    }

    private var nameBinding: Binding<String> {
        let car = app.car, id = card.id
        return Binding(get: { car.cards.first { $0.id == id }?.name ?? "" }, set: { v in
            if let i = car.cards.firstIndex(where: { $0.id == id }) { car.cards[i].name = v; app.saveCar() }
        })
    }
}

// MARK: Combinations

struct CombinationsPane: View {
    @Environment(AppState.self) private var app
    var embedded = false  // in Wing Lab's inspector: its section header is the title, no pane
    @Environment(\.undoManager) private var undo

    var body: some View {
        @Bindable var car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            HStack {
                if !embedded { Text("Combinations").font(.system(size: 20, weight: .semibold)) }
                Spacer()
                Button("Add") { add() }.disabled(car.combos.count >= 12)
            }
            ForEach(car.combos) { combo in row(combo) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carPane(embedded)
    }

    private func add() {
        let car = app.car
        let c = Combination(id: UUID().uuidString, name: "Car \(car.combos.count + 1)")
        car.combos.append(c)
        car.selected = c.id
        app.saveCar()
    }

    @ViewBuilder private func row(_ combo: Combination) -> some View {
        let car = app.car
        let selected = car.selected == combo.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(combo.name).font(.system(size: 16, weight: .semibold))
                Text([combo.front.flatMap { car.card($0.card)?.name }, combo.rear.flatMap { car.card($0.card)?.name }]
                    .compactMap { $0 }.joined(separator: " + ").ifEmpty("no wings"))
                    .font(.caption).foregroundStyle(S37.C.inkSecondary)
                Spacer()
            }
            HStack {
                Spacer()
                Button("Remove") {
                    let old = car.combos
                    undo?.registerUndo(withTarget: car) { model in MainActor.assumeIsolated { model.combos = old } }
                    undo?.setActionName("Remove \(combo.name)")
                    car.combos.removeAll { $0.id == combo.id }
                    app.saveCar()
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(S37.Space.s3)
        .background(RoundedRectangle(cornerRadius: S37.Radius.lgIn, style: .continuous)
            .fill(selected ? S37.C.sageWash : S37.C.inset))
        .contentShape(Rectangle())
        .onTapGesture { car.selected = combo.id }
    }
}

private extension View {
    @ViewBuilder func carPane(_ embedded: Bool) -> some View {
        if embedded { self } else { s37Pane() }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
