import AeroBenchKit
import AppKit
import Foundation

extension AppState {
    /// Edit Part mode on the open STEP: loads the saved edits beside it and
    /// rebuilds through a warm engine of its own.
    func enterPartEdit() {
        guard let url = cad.fileURL, cad.isStep else { return }
        guard let executable = settings.engineExecutable else {
            alert = AppAlert(title: "The engine is not set up", message: "Set the engine folder in Settings.")
            return
        }
        if partEdit.engine == nil { partEdit.engine = WarmEngine(executableURL: executable) }
        guard let engine = partEdit.engine else { return }
        partEdit.viewer = cad.viewer
        partEdit.showModel = { [weak self] model in self?.cad.showEdited(model) }
        partEdit.showError = { [weak self] title, error in self?.show(title, error) }
        cad.viewer.onEditHover = { [weak self] p in self?.partEdit.hover(p) }
        cad.viewer.onEditClick = { [weak self] p in self?.partEdit.pick(p) }
        partEdit.start(step: url, engine: engine)
    }

    func exitPartEdit(reload: Bool = true) {
        partEdit.stop()
        cad.viewer.onEditHover = nil
        cad.viewer.onEditClick = nil
        if reload { reloadCAD() }
    }

    /// An imported part that is not a valid solid is repaired first.
    func repairBeforeEditing() {
        exitPartEdit()
        planBodyRepair()
    }

    func savePartEdit() {
        guard let url = cad.fileURL, partEdit.reply != nil, !partEdit.saving else { return }
        if let d = partEdit.draft, partEdit.ready(d) {
            partEdit.status = "Apply or cancel the \(PartEditModel.describe(d)) first: Save writes the applied features"
            return
        }
        var params: [String: JSONValue] = ["path": .string(url.path)]
        if let part = partEdit.file.part { params["part"] = .string(part) }
        if let fp = partEdit.file.fingerprint { params["fingerprint"] = .string(fp) }
        do {
            params["features"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(partEdit.file.features))
        } catch {
            show("Could not send the edits to the engine", error)
            return
        }
        partEdit.saving = true
        _ = jobs.submit(command: "part-save", params: params, in: jobsRoot) { [weak self] item in
            guard let self else { return }
            self.partEdit.saving = false
            guard item.status == .succeeded, let text = item.resultText,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let data = obj["data"] as? [String: Any], let name = data["output"] as? String else {
                self.partEdit.status = item.message ?? "The part could not be saved"
                return
            }
            // Edit Part stays open until the file is saved: cancelling the panel keeps the edits on screen.
            self.saveRepaired(item, name: name, beside: url) { self.exitPartEdit(reload: false) }
        }
    }
}
