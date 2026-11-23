import PlaydeckCore
import SwiftUI

/// One color / symbol / label per state, used everywhere (badges, tiles, gauges).
enum StateKind: CaseIterable {
    case upToDate, outdated, neverDeployed

    init(_ state: DeployState) {
        self = switch state {
        case .upToDate: .upToDate
        case .outdated: .outdated
        case .neverDeployed: .neverDeployed
        }
    }

    var color: Color {
        switch self { case .upToDate: .green; case .outdated: .orange; case .neverDeployed: .gray }
    }
    var symbol: String {
        switch self {
        case .upToDate: "checkmark.circle.fill"
        case .outdated: "clock.badge.exclamationmark.fill"
        case .neverDeployed: "circle.dashed"
        }
    }
    var label: String {
        switch self { case .upToDate: "À jour"; case .outdated: "En retard"; case .neverDeployed: "Jamais déployée" }
    }
    var plural: String {
        switch self { case .upToDate: "à jour"; case .outdated: "en retard"; case .neverDeployed: "jamais déployées" }
    }

    func count(in c: StatusCounts) -> Int {
        switch self { case .upToDate: c.upToDate; case .outdated: c.outdated; case .neverDeployed: c.neverDeployed }
    }
}

extension HostDeployStatus {
    /// Tooltip text: hash/date of the last deployment.
    var help: String {
        var parts: [String] = []
        if case let .outdated(version, date) = state {
            parts.append("Hash \(version) déployé le \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: "\n")
    }
}

/// Colored symbol + label; the symbol bounces when the state changes.
struct StatusBadge: View {
    let status: HostDeployStatus
    var compact = false

    var body: some View {
        let kind = StateKind(status.state)
        let label: String = if case let .outdated(version, _) = status.state { "En retard (\(version))" } else { kind.label }
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: status.state)
                .accessibilityHidden(true)
            if !compact {
                Text(label).lineLimit(1)
            }
        }
        .font(.caption)
        .animation(.snappy, value: status)
        .help(status.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// Three colored counter tiles.
struct CounterTiles: View {
    let counts: StatusCounts

    var body: some View {
        HStack(spacing: 8) {
            ForEach(StateKind.allCases, id: \.self) { kind in
                let n = kind.count(in: counts)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: kind.symbol).accessibilityHidden(true)
                        Text("\(n)").font(.title2.bold().monospacedDigit()).contentTransition(.numericText())
                    }
                    .foregroundStyle(kind.color)
                    Text(kind.plural).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(kind.color.opacity(n > 0 ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(n) \(kind.plural)")
            }
        }
        .animation(.snappy, value: counts)
    }
}

/// Horizontal stacked bar (green / orange / gray) proportional to the counts.
struct StatusGauge: View {
    let counts: StatusCounts

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                if counts.total == 0 {
                    Capsule().fill(Color.secondary.opacity(0.2))
                } else {
                    ForEach(StateKind.allCases, id: \.self) { kind in
                        let n = kind.count(in: counts)
                        if n > 0 { Rectangle().fill(kind.color).frame(width: geo.size.width * CGFloat(n) / CGFloat(counts.total)) }
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .animation(.snappy, value: counts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StateKind.allCases.map { "\($0.count(in: counts)) \($0.plural)" }.joined(separator: ", "))
    }
}

/// Per-host result of a run (success / failure / unreachable).
struct ResultBadge: View {
    let result: HostResult

    var body: some View {
        let (label, color): (String, Color) = switch result.status {
        case .success: ("Succès", .green)
        case .failed: ("Échec", .red)
        case .unreachable: ("Injoignable", .orange)
        }
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .help("ok=\(result.ok) changed=\(result.changed) unreachable=\(result.unreachable) failed=\(result.failed) skipped=\(result.skipped) rescued=\(result.rescued) ignored=\(result.ignored)"
                  + (result.missing ? " (absente du recap)" : ""))
    }
}

extension HostResult: Identifiable {
    public var id: String { host }
}

extension Run {
    /// « 3/4 en succès », « annulé »…
    var summary: String {
        if cancelled { return "annulé" }
        let ok = results.filter { $0.status == .success }.count
        return "\(ok)/\(results.count) en succès" + (ledgerError != nil ? " · hash non noté" : "")
    }
    var failed: Bool { cancelled || exitCode != 0 || ledgerError != nil }
}

extension Grade {
    /// A–B green, C yellow, D orange, E–F red (same palette as the host states).
    var color: Color {
        switch self { case .A: .green; case .B: .mint; case .C: .yellow; case .D: .orange; case .E, .F: .red }
    }
}

/// ansible-lint grade in a small colored square.
struct GradeBadge: View {
    let grade: Grade
    var help = ""

    var body: some View {
        Text(grade.rawValue)
            .font(.caption.bold().monospaced())
            .frame(width: 20, height: 18)
            .background(grade.color, in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(grade == .C ? Color.black : .white)
            .help(help.isEmpty ? "Note ansible-lint \(grade.rawValue)" : help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Note \(grade.rawValue)")
    }
}
