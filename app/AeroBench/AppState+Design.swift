import AeroBenchKit
import Foundation

/// The Design card: one wing-design job from the rules box to RANS-checked
/// finalists, and putting the one picked on the canvas, a card and the car.
extension AppState {
    /// The box a design runs in, in the design frame (m: x downstream from the
    /// box's front, y up from the ground), whether it is in free air, and what
    /// to add to the canvas wing's coordinates to put it in that frame.
    struct DesignFrame {
        var box: RulesBox
        var freeAir: Bool
        var offset: SIMD2<Double>?  // nil: the canvas wing has no place in it (start from scratch only)
        var onCar: Bool
    }

    var designFrame: DesignFrame {
        let wing = wingLab.wing
        let pts = wing.elements.flatMap { $0.placed() }
        let lo = SIMD2(pts.map(\.x).min() ?? 0, pts.map(\.y).min() ?? 0)
        if let s = car.setup {
            let end = wing.rulesFor
            let b = CarRules.box(end, setup: s, span: wing.span)  // the rear starts at the lowest band its span fits
            var offset: SIMD2<Double>?
            if let at = carDraftAt, !pts.isEmpty {
                let front = (b.maxX - (s.axleX(end == .front ? "F" : "R") + at.x)) / 1000
                offset = SIMD2(front, at.height / 1000) - lo
            }
            return DesignFrame(box: CarRules.designBox(end, setup: s, span: wing.span), freeAir: false, offset: offset, onCar: true)
        }
        let box = wing.rulesBox ?? rulesBox(for: wing.rulesFor)  // the last base car's, if this project has none
        if let h = wing.rideHeight, !pts.isEmpty {
            let shift = SIMD2(-box.minX, h - lo.y)  // the ground at y = 0
            return DesignFrame(box: RulesBox(minX: 0, minY: box.minY + shift.y, maxX: box.maxX - box.minX, maxY: box.maxY + shift.y),
                               freeAir: false, offset: shift, onCar: false)
        }
        return DesignFrame(box: RulesBox(minX: 0, minY: 0, maxX: box.maxX - box.minX, maxY: box.maxY - box.minY),
                           freeAir: true, offset: pts.isEmpty ? nil : SIMD2(-box.minX, -box.minY), onCar: false)
    }

    /// The design's job params, without the study's name.
    private func designParams() throws -> [String: JSONValue] {
        let lab = wingLab, wing = lab.wing, d = lab.design, f = designFrame
        if d.startFrom == .existing, abs(wing.alpha) > 1e-9 {
            throw WingLabError("Set the wing's angle to 0° first: a design turns its elements, not the whole wing.")
        }
        var p = ransParams()
        p["ref_chord"] = nil
        p["ride_height"] = nil
        p["alpha"] = .double(0)  // designs are scored and shown at 0°: the box and the car take the elements as drawn
        func pair(_ v: SIMD2<Double>) -> JSONValue { .array([.double(v.x), .double(v.y)]) }
        p["box"] = .array([f.box.minX, f.box.minY, f.box.maxX, f.box.maxY].map { .double($0) })
        p["free_air"] = .bool(f.freeAir)
        p["elements"] = .int(d.startFrom == .existing ? wing.elements.count : d.elements)
        p["inverted"] = .bool(wing.elements.first?.inverted ?? true)
        p["goal"] = .string(d.goal.rawValue)
        p["span"] = .double(wing.span)
        p["factor"] = .double(wing.factor3D)
        if let h = wing.endplateHeight { p["endplate"] = .double(h) }
        p["cda_cap"] = .double(d.cdaCap)
        p["rear_target"] = .double(d.rearTarget / 100)
        p["trials"] = .int(lab.optimise.trials)
        p["sampler"] = .string(lab.optimise.sampler)
        p["checks"] = .int(settings.su2Executable == nil ? 0 : d.checks)
        p["min_thickness"] = .double(d.minThickness / 100)
        p["min_gap"] = .double(wing.minGap)
        if f.onCar, let s = car.setup, car.base != nil {
            let end = wing.rulesFor
            let others = (car.selectedCombo ?? Combination(id: "", name: "")).without(end)
            if let q = quickResult(others) {
                let b = CarRules.box(end, setup: s)
                p["car"] = .object(["base_cla": .double(q.cla), "base_cda": .double(q.cda),
                                    "base_rear_cla": .double((q.rearShare ?? 0) * q.cla),
                                    "axle_front": .double((b.maxX - s.axleX("F")) / 1000),
                                    "axle_rear": .double((b.maxX - s.axleX("R")) / 1000)])
            }
        }
        if d.goal == .minLapTime { p["lap"] = try lapObjectiveParams() }
        if d.startFrom == .existing {
            guard let offset = f.offset else { throw WingLabError("Put the wing on the car first, or start from scratch.") }
            p["start"] = .array(wing.elements.map { e in
                .object(["unit": .array(e.airfoil.coords.map(pair)), "chord": .double(e.chord), "angle": .double(e.angle),
                         "leading_edge": pair(e.leadingEdge + offset), "inverted": .bool(e.inverted),
                         "key": .string(e.airfoil.key)])
            })
        }
        return p
    }

    /// Runs the Design card: a new study, or the last one resumed while nothing but the RANS checks changed.
    func runDesign() {
        let lab = wingLab
        var params: [String: JSONValue]
        do {
            params = try designParams()
        } catch {
            show("The design cannot start", error)
            return
        }
        var keyed = params
        keyed["checks"] = nil
        let key = (try? String(decoding: AeroJSON.encoder().encode(JSONValue.object(keyed)), as: UTF8.self)) ?? UUID().uuidString
        if key != lab.designKey || lab.designName == nil {
            lab.designName = nextDesignName()
            lab.designKey = key
        }
        let file = WingLabModel.studyFile(project: workFolder, name: lab.designName!)
        params["storage"] = .string(file.path)
        params["name"] = .string(file.deletingPathExtension().lastPathComponent)
        lab.designResult = nil
        lab.designShown = nil
        let resultFile = WingLabModel.designResultFile(project: workFolder, name: lab.designName!)
        saveProject()  // the chips and the study's name, so a relaunch can resume it
        lab.designRun = jobs.submit(command: "wing-design", params: params, in: jobsRoot) { [weak self] item in
            guard let self else { return }
            guard item.status == .succeeded, let text = item.resultText,
                  let r = try? WingDesignResult.decode(resultFile: Data(text.utf8)) else {
                if item.status == .failed { self.show("The design did not finish", WingLabError(item.message ?? "The design failed.")) }
                return
            }
            try? Data(text.utf8).write(to: resultFile, options: .atomic)
            self.wingLab.designResult = r
        }
    }

    /// The finalist on the canvas (one undo step), in the design frame, and its place on the car.
    func showFinalist(_ f: WingDesignResult.Finalist) {
        let lab = wingLab
        guard let r = lab.designResult, let trial = r.study.trials.first(where: { $0.number == f.number }) else { return }
        var base = lab.wing
        base.elements = r.base.elements.enumerated().map { i, e in
            let coords = e.unit.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
            let airfoil = e.key.flatMap { lab.airfoil($0) } ?? lab.wing.elements.indices.contains(i).then { lab.wing.elements[i].airfoil }
                ?? Airfoil(key: e.key ?? "design/\(i)", name: e.name ?? "Section \(i + 1)", family: "NACA", source: "design",
                           thickness: (coords.map(\.y).max() ?? 0) - (coords.map(\.y).min() ?? 0), thicknessX: 0.3,
                           camber: 0, camberX: 0.4, teThickness: 0, coords: coords)
            return WingElement(airfoil: airfoil, chord: e.chord, angle: e.angle,
                               leadingEdge: SIMD2(e.leadingEdge.count == 2 ? e.leadingEdge[0] : 0, e.leadingEdge.count == 2 ? e.leadingEdge[1] : 0),
                               inverted: e.inverted)
        }
        base.alpha = 0
        var w = base.applying(trial, library: { lab.airfoil($0) }) ?? base
        w.rideHeight = f.rideHeight
        let frame = designFrame
        if !frame.onCar { w.rulesBox = frame.box }  // on the car the car's box follows the placement
        var x = lab.carX
        if frame.onCar, let s = car.setup {
            let card = WingCard.make(wing: w, cl: 0, cd: 0, solver: "", id: "draft", name: "", revision: -1)
            x = Placement.fromDesign(card: card, x: f.x, setup: s).x
        }
        lab.editStep { $0 = WingLabModel.Step(wing: w, cardID: nil, carX: x) }
        lab.markOrigin("\(r.study.study) · finalist \(f.number)")
        lab.designShown = f.number
    }

    /// The final design: on the canvas, saved as a new card with its RANS numbers (or the estimate's),
    /// and on the car's selected combination.
    func useFinalist(_ f: WingDesignResult.Finalist) {
        showFinalist(f)
        if car.setup != nil { putDraftOnCar() }
        let wing = wingLab.wing
        let ref = wingLab.designResult?.base.elements.reduce(0) { $0 + $1.chord } ?? wing.refChord
        // The study's coefficients are on its starting wing's total chord: the card's go on its own.
        // RANS's when it held, else the finalist's own estimate (never the live one: not back yet for this wing).
        let trial = wingLab.designResult?.study.trials.first { $0.number == f.number }
        let ran: (Double, Double, String)? = f.held ? f.rans.flatMap { v in v.cl.flatMap { cl in v.cd.map { (cl, $0, "RANS (design)") } } } : nil
        let est: (Double, Double, String)? = trial.flatMap { t in t.cl.flatMap { cl in t.cd.map { (cl, $0, "estimate (design)") } } }
        guard let (cl, cd, name) = ran ?? est else {
            show("Could not save the design", WingLabError("This finalist has no numbers to save."))
            return
        }
        saveWingCard(asNew: true, numbers: (cl * ref / wing.refChord, cd * ref / wing.refChord, name))
    }
}

private extension Bool {
    func then<T>(_ value: () -> T) -> T? { self ? value() : nil }
}
