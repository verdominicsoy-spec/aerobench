import AeroBenchKit
import SwiftUI

/// The Car tool: the base car from its STEP, its 2D strip runs, and front
/// and rear wing cards placed on it, compared quickly (sums) or fully (the
/// strips again with the wings in them), then sent to Lap Sim.
struct CarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo

    var body: some View {
        let car = app.car
        ScrollView {
            VStack(alignment: .leading, spacing: S37.Space.s6) {
                HStack(alignment: .top, spacing: S37.Space.s6) {
                    BaseCarPane().frame(maxWidth: 420)
                    VStack(alignment: .leading, spacing: S37.Space.s6) {
                        SideViewPane()
                        SectionPane()
                    }
                }
                HStack(alignment: .top, spacing: S37.Space.s6) {
                    CardsPane().frame(maxWidth: 420)
                    CombinationsPane()
                }
            }
            .padding(6)
        }
        .scrollIndicators(.never)
        .onAppear { app.loadCar(); app.refreshSections() }
        .preference(key: ToolTakeawayKey.self, value: takeaway(car))
    }

    private func takeaway(_ car: CarModel) -> String {
        guard car.setup != nil else { return "Choose the base car's STEP to start." }
        guard let b = car.base else { return "Run the bare car at the \(car.mesh) mesh to get its numbers." }
        let rear = b.rearShare.map { String(format: ", %.0f %% on the rear axle", $0 * 100) } ?? ""
        return String(format: "Bare car: ClA %.2f m², CdA %.2f m²", b.cla, b.cda) + rear + (b.converged ? "." : " (not converged).")
    }
}

// MARK: Base car

private struct BaseCarPane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text("Base car").font(.system(size: 20, weight: .semibold))
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
                NumberField(label: "Car speed", unit: "m/s", digits: 1, value: setupBinding(\.speed))
                HStack {
                    Toggle("Moving ground", isOn: $car.groundMoving)
                    if car.groundMoving { NumberField(label: "at", unit: "m/s", digits: 1, value: $car.groundSpeed) }
                }
                HStack {
                    Toggle("Rotating wheels", isOn: $car.wheelsRotating)
                    if car.wheelsRotating { NumberField(label: "at", unit: "m/s", digits: 1, value: $car.wheelsSpeed) }
                }
                S37Segmented(options: CarModel.meshes.map { ($0, $0.capitalized) }, selection: $car.mesh)
                Stepper("Strips across half the car: \(car.strips)", value: $car.strips, in: 3...15)
                HStack {
                    Button("Run Bare Car") { app.runBareCar() }
                        .buttonStyle(S37ButtonStyle(kind: .prominent))
                        .disabled(car.baseJob.map { !$0.status.isFinished } ?? false)
                    if let j = car.baseJob, !j.status.isFinished {
                        ProgressView(value: j.progress, total: 100).frame(maxWidth: 120)
                        Text(j.progressMessage).font(.caption).lineLimit(1)
                    }
                }
                if let j = car.baseJob, j.status == .failed {
                    Label(j.message ?? "The run failed", systemImage: "xmark.octagon").foregroundStyle(S37.C.critical)
                }
                if car.baseMismatch {
                    Text("The bare car was run with other settings (strips, speed, ground or wheels): run it again for these.")
                        .font(.caption).foregroundStyle(S37.C.inkSecondary)
                }
                if let b = car.base {
                    Text(String(format: "ClA %.3f m²   CdA %.3f m²   ", b.cla, b.cda) + rearText(b.rearShare))
                        .monospacedDigit()
                    if !b.converged {
                        Text("\(b.strips.filter { !$0.converged }.count) of \(b.strips.count) strips did not converge")
                            .font(.caption).foregroundStyle(S37.C.clayInk)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .s37Pane()
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
private struct CarFrame {
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

private struct SideViewPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.undoManager) private var undo
    @State private var dragging: WingPosition?
    @State private var startPlacement: Placement?

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
            if let combo = car.selectedCombo {
                placementFields(combo, .front)
                placementFields(combo, .rear)
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
        guard let combo = car.selectedCombo else { return }
        for p in [combo.front, combo.rear].compactMap({ $0 }) {
            guard let c = car.card(p.card) else { continue }
            for el in p.placedElements(card: c, setup: s) {
                let path = outlinePath(el.map { [$0.x, $0.y] }, f)
                ctx.fill(path, with: .color(S37.C.sage.opacity(0.5)))
                ctx.stroke(path, with: .color(S37.C.sageInk), lineWidth: 1)
            }
        }
    }

    private func hit(_ point: CGPoint, _ f: CarFrame) -> WingPosition? {
        let car = app.car
        guard let s = car.setup, let combo = car.selectedCombo else { return nil }
        let (x, z) = f.car(point)
        for (pos, p) in [(WingPosition.front, combo.front), (.rear, combo.rear)] {
            guard let p, let c = car.card(p.card) else { continue }
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
            if let pos = dragging, let combo = car.selectedCombo { startPlacement = pos == .front ? combo.front : combo.rear }
        }
        guard let pos = dragging, var p = startPlacement, let c = car.card(p.card), let s = car.setup else { return }
        p.x -= Double(g.translation.width) / f.scale
        p.height -= Double(g.translation.height) / f.scale
        set(pos, p.clamped(card: c, setup: s).0, undoable: false)
    }

    private func endDrag(_ g: DragGesture.Value, _ f: CarFrame) {
        let car = app.car
        if car.markingHeadRestraint {
            car.markingHeadRestraint = false
            app.setupChanged()
            return
        }
        if let pos = dragging, let before = startPlacement, let combo = car.selectedCombo,
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
        if let p, let c = car.card(p.card) { app.estimateCard(c, height: p.height / 1000) }
        guard undoable else { return }
        undo?.registerUndo(withTarget: car) { model in MainActor.assumeIsolated { model.combos = old } }
        undo?.setActionName("Move \(pos == .front ? "Front" : "Rear") Wing")
        app.saveCar()
    }

    @ViewBuilder private func placementFields(_ combo: Combination, _ pos: WingPosition) -> some View {
        if let p = pos == .front ? combo.front : combo.rear, let c = app.car.card(p.card), let s = app.car.setup {
            HStack {
                Text("\(pos == .front ? "Front" : "Rear"): \(c.name)").frame(width: 140, alignment: .leading)
                NumberField(label: "ahead of axle", unit: "mm", digits: 0, value: Binding(get: { p.x }, set: { v in
                    var q = p; q.x = v; set(pos, q.clamped(card: c, setup: s).0, undoable: true) }))
                NumberField(label: "above ground", unit: "mm", digits: 0, value: Binding(get: { p.height }, set: { v in
                    var q = p; q.height = v; set(pos, q.clamped(card: c, setup: s).0, undoable: true) }))
            }
        }
    }
}

// MARK: Section

private struct SectionPane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            HStack {
                Text("Section").font(.system(size: 20, weight: .semibold))
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
        .s37Pane()
    }
}

// MARK: Cards

private struct CardsPane: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            Text("Wing cards").font(.system(size: 20, weight: .semibold))
            if car.cards.isEmpty {
                Text("Save a wing as a card in Wing Lab (Lap Sim section).").font(.caption).foregroundStyle(S37.C.inkSecondary)
            }
            ForEach(car.cards) { c in
                CardRow(card: c) { assign(c) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .s37Pane()
    }

    private func assign(_ c: WingCard) {
        let car = app.car
        guard let i = car.combos.firstIndex(where: { $0.id == car.selected }), let s = car.setup else { return }
        let box = CarRules.box(c.position, setup: s)
        let axle = s.axleX(c.position == .front ? "F" : "R")
        let start = Placement(card: c.id, x: box.maxX - axle - 10, height: max(c.rideHeight.map { $0 * 1000 } ?? 0, box.minZ - s.groundZ) + 10)
        let placed = start.clamped(card: c, setup: s).0
        if c.position == .front { car.combos[i].front = placed } else { car.combos[i].rear = placed }
        app.estimateCard(c, height: placed.height / 1000)
        app.saveCar()
    }
}

private struct CardRow: View {
    @Environment(AppState.self) private var app
    let card: WingCard
    let put: () -> Void

    var body: some View {
        let car = app.car
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                TextField("Name", text: nameBinding).textFieldStyle(.plain).font(.system(size: 16, weight: .semibold))
                Text(card.position == .front ? "Front" : "Rear").font(.caption).foregroundStyle(S37.C.inkSecondary)
                Spacer()
                Button("Put on Car", action: put).disabled(car.selectedCombo == nil || car.setup == nil)
            }
            Text(String(format: "ClA %.3f   CdA %.3f   ", card.cla, card.cda) + card.solver).font(.caption).monospacedDigit()
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

private struct CombinationsPane: View {
    @Environment(AppState.self) private var app
    @State private var note: String?

    var body: some View {
        @Bindable var car = app.car
        VStack(alignment: .leading, spacing: S37.Space.s3) {
            HStack {
                Text("Combinations").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Add") { add() }.disabled(car.combos.count >= 12)
            }
            ForEach(car.combos) { combo in row(combo) }
            if let note { Text(note).font(.caption).foregroundStyle(S37.C.sageInk) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .s37Pane()
    }

    private func add() {
        let car = app.car
        var c = Combination(id: UUID().uuidString, name: "Car \(car.combos.count + 1)")
        c.baseRevision = car.baseRevision
        car.combos.append(c)
        car.selected = c.id
        app.saveCar()
    }

    @ViewBuilder private func row(_ combo: Combination) -> some View {
        let car = app.car
        let stale = combo.isStale(cards: car.cards, baseRevision: car.baseRevision)
        let quick = car.quickResult(combo)
        let selected = car.selected == combo.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(combo.name).font(.system(size: 16, weight: .semibold))
                Text([combo.front.flatMap { car.card($0.card)?.name }, combo.rear.flatMap { car.card($0.card)?.name }]
                    .compactMap { $0 }.joined(separator: " + ").ifEmpty("no wings"))
                    .font(.caption).foregroundStyle(S37.C.inkSecondary)
                Spacer()
                if stale { Text("Out of date").font(.caption.weight(.semibold)).foregroundStyle(S37.C.clayInk) }
            }
            if let q = quick {
                Text(String(format: "Quick: ClA %.3f   CdA %.3f   ", q.cla, q.cda) + rearText(q.rearShare)
                     + (q.usedEstimate.isEmpty ? "" : "  (re-estimated at the placed height)")
                     + (q.pendingEstimate.isEmpty ? "" : "  (card's own height: estimate pending)"))
                    .font(.caption).monospacedDigit()
            } else {
                Text("Quick: run the bare car first").font(.caption).foregroundStyle(S37.C.inkSecondary)
            }
            if let f = combo.full {
                Text(String(format: "Full (%@): ClA %.3f   CdA %.3f   ", f.mesh, f.cla, f.cda) + rearText(f.rearShare)
                     + (f.converged ? "" : "  not converged"))
                    .font(.caption).monospacedDigit().foregroundStyle(f.converged ? S37.C.ink : S37.C.clayInk)
            }
            HStack {
                Button("Run Full") { app.runFull(combo.id) }
                    .disabled(car.base == nil || (car.fullJob.map { !$0.status.isFinished } ?? false))
                    .help(car.base == nil ? "Run the bare car at this mesh setting first" : "The strips again with these wings in them")
                Menu("Send to Lap Sim") {
                    ForEach(app.lapSim.cars.indices, id: \.self) { i in
                        Button("Car \(LapSimSetup.labels[i]) (quick)") { send(combo, full: false, i) }
                        if combo.full != nil { Button("Car \(LapSimSetup.labels[i]) (full)") { send(combo, full: true, i) } }
                    }
                    if app.lapSim.cars.count < LapSimSetup.maxCars {
                        Button("New car (quick)") { send(combo, full: false, nil) }
                    }
                }
                .fixedSize()
                .disabled(quick == nil)
                Spacer()
                Button("Remove") { car.combos.removeAll { $0.id == combo.id }; app.saveCar() }.buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(S37.Space.s3)
        .background(RoundedRectangle(cornerRadius: S37.Radius.lgIn, style: .continuous)
            .fill(selected ? S37.C.sageWash : S37.C.inset))
        .contentShape(Rectangle())
        .onTapGesture { car.selected = combo.id }
    }

    private func send(_ combo: Combination, full: Bool, _ i: Int?) {
        if let sent = app.sendCarToLapSim(combo.id, full: full, into: i) {
            note = "Lap Sim car \(sent.label) now has \(combo.name) (\(full ? "full" : "quick") numbers)."
                + (sent.warnings.isEmpty ? "" : " Note: " + sent.warnings.joined(separator: "; ") + ".")
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

private func rearText(_ share: Double?) -> String {
    share.map { String(format: "rear %.0f %%", $0 * 100) } ?? "no rear share (no net downforce)"
}
