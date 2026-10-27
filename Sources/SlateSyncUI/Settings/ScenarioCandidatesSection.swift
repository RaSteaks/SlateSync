import SlateSyncDomain
import SwiftUI

/// Uses the owning project form and native controls. Candidate confirmation is
/// an explicit commit independent of unsaved project-setting fields.
struct ScenarioCandidatesSection: View {
    let model: ProjectSettingsModel

    var body: some View {
        Section(L10n.tr("待确认的场记版式")) {
            Text(L10n.tr("识别不会自动新增正式模板。确认新版式，或将候选关联到已有版式。"))
                .font(.callout).foregroundStyle(.secondary)
            if model.scenarioCandidates.isEmpty {
                Text(L10n.tr("暂无待确认版式"))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.scenarioCandidates, id: \.id) { candidate in
                ScenarioCandidateRow(candidate: candidate, model: model)
            }
            if model.scenarios.count > 1 || model.lastScenarioMerge != nil {
                ScenarioMergeControls(model: model)
            }
            Button(L10n.tr("刷新版式列表"), systemImage: "arrow.clockwise") {
                Task { await model.refreshScenarios() }
            }
            .disabled(model.scenarioOperation.isRunning)
            if case .running(let label) = model.scenarioOperation {
                ProgressView(label).controlSize(.small)
            } else if case .failed(let error) = model.scenarioOperation {
                SlateInlineError(error.message)
            } else if case .succeeded(let message) = model.scenarioOperation {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScenarioMergeControls: View {
    let model: ProjectSettingsModel
    @State private var sourceID = ""
    @State private var targetID = ""

    var body: some View {
        DisclosureGroup(L10n.tr("整理重复版式")) {
            if model.scenarios.count > 1 {
                Picker(L10n.tr("待合并版式"), selection: $sourceID) {
                    Text(L10n.tr("请选择")).tag("")
                    ForEach(model.scenarios, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker(L10n.tr("保留的版式"), selection: $targetID) {
                    Text(L10n.tr("请选择")).tag("")
                    ForEach(model.scenarios, id: \.id) { Text($0.label).tag($0.id) }
                }
                Button(L10n.tr("预览合并")) {
                    Task { await model.previewScenarioMerge(sourceID: sourceID, targetID: targetID) }
                }
                .disabled(sourceID.isEmpty || targetID.isEmpty || sourceID == targetID)
            }
            if let preview = model.scenarioMergePreview {
                Text(L10n.tr("将“{0}”合并到“{1}”", [preview.source.label, preview.target.label]))
                Text(L10n.tr("合并后使用目标版式。已有识别结果保持原样，可撤销。"))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(preview.warnings, id: \.self) { Text(L10n.tr($0)).font(.callout) }
                Button(L10n.tr("确认合并")) { Task { await model.commitScenarioMerge() } }
            }
            if let receipt = model.lastScenarioMerge {
                Text(L10n.tr("已合并：“{0}” → “{1}”", [receipt.sourceLabel, receipt.targetLabel]))
                Button(L10n.tr("撤销上次版式合并")) { Task { await model.undoScenarioMerge() } }
            }
        }
        .disabled(model.scenarioOperation.isRunning)
        .onChange(of: sourceID) { model.clearScenarioMergePreview() }
        .onChange(of: targetID) { model.clearScenarioMergePreview() }
    }
}

private struct ScenarioCandidateRow: View {
    let candidate: ScenarioCandidate
    let model: ProjectSettingsModel
    @State private var name: String
    @State private var existingID = ""
    @State private var expanded: Bool

    init(candidate: ScenarioCandidate, model: ProjectSettingsModel) {
        self.candidate = candidate; self.model = model
        // The stable observation ID owns this one-time editable seed. Refreshing
        // the same candidate must not replace a name the user is composing.
        _name = State(initialValue: candidate.profile.label)
        _expanded = State(initialValue: model.scenarioCandidates.count == 1)
    }

    var body: some View {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        DisclosureGroup(isExpanded: $expanded) {
            LabeledContent(L10n.tr("识别到的表头"), value: candidate.profile.recognition.headerTokens.map { L10n.tr($0) }.joined(separator: " → "))
                .textSelection(.enabled)
            Picker(L10n.tr("归属版式"), selection: $existingID) {
                Text(L10n.tr("创建新版式")).tag("")
                ForEach(model.scenarios, id: \.id) { Text($0.label).tag($0.id) }
            }
            TextField(L10n.tr("版式名称"), text: $name)
                .disabled(!existingID.isEmpty)
            if existingID.isEmpty && cleanedName.count > 120 {
                SlateInlineError(L10n.tr("场记版式名称须为 1–120 个字符"))
            }
            Button(L10n.tr("确认版式")) {
                Task { await model.confirmCandidate(candidate, label: cleanedName, existingProfileID: existingID.isEmpty ? nil : existingID) }
            }
            .disabled(model.scenarioOperation.isRunning || (existingID.isEmpty && (cleanedName.isEmpty || cleanedName.count > 120)))
            .accessibilityIdentifier("project.scenario.confirm.\(candidate.id)")
        } label: {
            Text(L10n.tr("{0} · {1} 份样本", [candidate.profile.label, String(candidate.sourceCount)]))
        }
        .disabled(model.scenarioOperation.isRunning)
    }
}
