import SwiftUI

/// Immutable report snapshots provide stable row identity, including duplicate
/// messages, and keep the entire diagnostic set reachable beyond inline caps.
struct WorkflowDiagnosticReport: Identifiable {
    struct Row: Identifiable { let id = UUID(); let message: String }
    let id = UUID()
    let title: String
    let rows: [Row]
    init(title: String, messages: [String]) {
        self.title = title
        rows = messages.map { Row(message: $0) }
    }
}

struct WorkflowDiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.slateSyncDensity) private var density
    let report: WorkflowDiagnosticReport

    var body: some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            SlatePanelHeading(title: report.title,
                subtitle: L10n.tr("{0} 项 · 可选择并复制文字", [String(report.rows.count)]))
            // One native list owns scrolling; full messages never truncate.
            List(report.rows) { row in
                Text(row.message).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, density.rowPadding)
            }
            HStack {
                Spacer()
                Button(L10n.tr("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(density.panelPadding)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 320, idealHeight: 480)
    }
}
