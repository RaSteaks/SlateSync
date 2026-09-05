import SwiftUI

public struct HelpView: View {
    @Bindable private var model: HelpModel
    public init(model: HelpModel) { self.model = model }

    public var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("语言 / Language", selection: $model.english) {
                    Text("简体中文").tag(false); Text("English").tag(true)
                }.padding(10)
                TextField("搜索帮助", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(AccessibilityID.helpSearch)
                    .padding(10)
                List(model.results, selection: $model.selection) { section in
                    Label(model.title(section), systemImage: section.symbol).tag(section.id)
                }
            }.frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            Group {
                if let section = model.sections.first(where: { $0.id == model.selection }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Label(model.title(section), systemImage: section.symbol).font(.title.bold())
                            Text(model.body(section)).font(.body).lineSpacing(5).textSelection(.enabled)
                            Divider()
                            Text("本帮助内容随 SlateSync 安装，无需网络。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(28).frame(maxWidth: 760, alignment: .leading)
                    }
                } else {
                    ContentUnavailableView("未找到内容", systemImage: "magnifyingglass", description: Text("请尝试 Provider、OCR、CSV 或日志。"))
                }
            }.frame(minWidth: 420)
        }
        .navigationTitle("帮助")
        // Resource errors stay visible instead of resembling empty search.
        .safeAreaInset(edge: .bottom) {
            if let error = model.resourceError { Text(error).padding(10) }
        }
        .onChange(of: model.results) {
            if !model.results.contains(where: { $0.id == model.selection }) {
                model.selection = model.results.first?.id
            }
        }
    }
}
