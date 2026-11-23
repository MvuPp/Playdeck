import Foundation

/// History export (JSON / CSV) and the end-of-batch notification text. Pure functions.
/// A `Run` never holds a secret (vault / sudo passwords live in `DeploySecrets`, which is not Codable),
/// so nothing exported here can leak one; `-e` variables typed by the user are exported as stored.
public enum RunExport {
    /// « 3 playbooks, 5/6 machines en succès » / « annulé ». A machine counts as a success when every playbook
    /// that ran on it succeeded; machines are counted once across the batch.
    public static func batchSummary(projectName: String, check: Bool, runs: [Run], cancelled: Bool) -> (title: String, body: String) {
        let title = "\(projectName) — \(check ? "simulation" : "déploiement réel")"
        if cancelled { return (title, runs.isEmpty ? "annulé" : "annulé après \(plural(runs.count, "playbook"))") }
        if runs.isEmpty { return (title, "aucun playbook lancé") }
        var ok: [String: Bool] = [:]
        for result in runs.flatMap(\.results) { ok[result.host] = (ok[result.host] ?? true) && result.status == .success }
        let succeeded = ok.values.filter { $0 }.count
        return (title, "\(plural(runs.count, "playbook")), \(succeeded)/\(ok.count) machine\(ok.count > 1 ? "s" : "") en succès")
    }

    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n > 1 ? "s" : "")" }

    /// The runs as stored (JSON array, same encoding as `RunStore`). Logs are emptied unless `includeLogs`.
    public static func json(_ runs: [Run], includeLogs: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(includeLogs ? runs : runs.map { var r = $0; r.log = []; return r })
    }

    public static let csvHeader = ["date", "projet", "playbook", "hash", "mode", "machine", "statut",
                                   "ok", "changed", "unreachable", "failed", "skipped", "batchID", "options"]

    /// One line per (run, machine), RFC 4180 (CRLF, quoted fields), formula-safe. A run without results
    /// (cancelled before the recap) gets one line per requested machine with a « annulé » / « inconnu » status.
    public static func csv(_ runs: [Run]) -> String {
        let iso = ISO8601DateFormatter()
        var rows = [csvHeader]
        for run in runs {
            let common = [iso.string(from: run.date), run.projectName, run.playbook, run.version, run.checkMode ? "simulation" : "réel"]
            let tail = [run.batchID?.uuidString ?? "", run.options?.arguments.joined(separator: " ") ?? ""]
            if run.results.isEmpty {
                for host in run.hosts { rows.append(common + [host, run.cancelled ? "annulé" : "inconnu", "", "", "", "", ""] + tail) }
            }
            for r in run.results {
                rows.append(common + [r.host, r.status.rawValue] + [r.ok, r.changed, r.unreachable, r.failed, r.skipped].map(String.init) + tail)
            }
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 field: a cell a spreadsheet would run as a formula (=, +, -, @, tab, CR) gets a leading `'`;
    /// a field with `"`, `,`, CR or LF is quoted, inner `"` doubled.
    public static func csvField(_ value: String) -> String {
        var v = value
        // Scalars, not Characters: "\r\n" is a single Character and would match neither "\r" nor "\n".
        if let first = v.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { v = "'" + v }
        guard v.unicodeScalars.contains(where: { "\",\r\n".unicodeScalars.contains($0) }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
