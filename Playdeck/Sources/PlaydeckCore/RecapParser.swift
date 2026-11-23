import Foundation

public enum HostStatus: String, Sendable, Codable {
    case success, failed, unreachable
}

/// One host's line of the PLAY RECAP.
public struct HostResult: Sendable, Equatable, Codable {
    public let host: String
    public var ok = 0, changed = 0, unreachable = 0, failed = 0, skipped = 0, rescued = 0, ignored = 0
    /// Requested but absent from the recap (e.g. run cancelled or crashed): counted as failed.
    public var missing = false

    public init(host: String) { self.host = host }

    public var status: HostStatus {
        unreachable > 0 ? .unreachable : (failed > 0 || missing) ? .failed : .success
    }
}

public enum RecapParser {
    /// Parses every PLAY RECAP block (counters summed per host). A host from `requested` that never
    /// appears in a recap is reported as failed. Result order: `requested`, then any extra recap hosts.
    public static func parse(_ lines: [String], requested: [String] = []) -> [HostResult] {
        var results: [String: HostResult] = [:]
        var order: [String] = []
        var inRecap = false
        for line in lines {
            if line.hasPrefix("PLAY RECAP") { inRecap = true; continue }
            guard inRecap else { continue }
            guard let colon = line.range(of: " : ") else {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { inRecap = false }
                continue
            }
            let host = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            var r = results[host] ?? HostResult(host: host)
            for pair in line[colon.upperBound...].split(separator: " ") {
                let kv = pair.split(separator: "=")
                guard kv.count == 2, let n = Int(kv[1]) else { continue }
                switch kv[0] {
                case "ok": r.ok += n
                case "changed": r.changed += n
                case "unreachable": r.unreachable += n
                case "failed": r.failed += n
                case "skipped": r.skipped += n
                case "rescued": r.rescued += n
                case "ignored": r.ignored += n
                default: break
                }
            }
            if results[host] == nil { order.append(host) }
            results[host] = r
        }
        let all = requested + order.filter { !requested.contains($0) }
        return all.map { host in
            results[host] ?? { var r = HostResult(host: host); r.missing = true; return r }()
        }
    }
}
