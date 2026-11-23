import PlaydeckCore
import SwiftUI

/// Bottom bar: batch progress (playbook i/n), cancel, and the collapsible live log.
struct BatchConsole: View {
    @Bindable var app: AppModel

    var body: some View {
        if let batch = app.batch {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    Button { withAnimation(.snappy) { app.showLog.toggle() } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(app.showLog ? 90 : 0))
                    }
                    .buttonStyle(.icon)
                    .accessibilityLabel(app.showLog ? "Replier le journal" : "Déplier le journal")
                    Image(systemName: batch.running ? "gearshape.2.fill" : "flag.checkered")
                        .symbolEffect(.pulse, isActive: batch.running)
                        .foregroundStyle(batch.running ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(batch.running
                             ? "\(batch.projectName) — playbook \(batch.index + 1)/\(batch.count) : \(batch.playbook)"
                             : "\(batch.projectName) — terminé (\(batch.finished)/\(batch.count))")
                            .font(.callout.bold()).lineLimit(1)
                        ProgressView(value: Double(batch.finished), total: Double(max(batch.count, 1)))
                            .tint(batch.check ? .blue : .orange)
                            .animation(.snappy, value: batch.finished)
                    }
                    Text(batch.check ? "simulation" : "réel").font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((batch.check ? Color.blue : .orange).opacity(0.2), in: Capsule())
                    if batch.running {
                        Button("Annuler", systemImage: "stop.fill", role: .cancel) { batch.deployment.cancel() }
                            .buttonStyle(.pill(.red))
                    } else {
                        Button { app.batch = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.icon).help("Fermer").accessibilityLabel("Fermer le journal")
                    }
                }
                .padding(8)
                if app.showLog {
                    LogConsole(lines: batch.log).frame(height: 170)
                }
            }
            .background(.bar)
        }
    }
}

/// Monospaced log that follows the last line.
struct LogConsole: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            // Both axes: Ansible lines (PLAY RECAP, ***) must not wrap.
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { i in
                        Text(lines[i].isEmpty ? " " : lines[i])
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .id(i)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) { _, count in if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) } }
        }
    }
}
