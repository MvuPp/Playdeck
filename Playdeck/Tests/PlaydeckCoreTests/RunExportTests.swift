import Foundation
import Testing
@testable import PlaydeckCore

private func result(_ host: String, failed: Int = 0, unreachable: Int = 0) -> HostResult {
    var r = HostResult(host: host); r.ok = 2; r.changed = 1; r.failed = failed; r.unreachable = unreachable
    return r
}

private func run(_ playbook: String, _ results: [HostResult], check: Bool = true, cancelled: Bool = false, options: DeployOptions? = nil,
                 batch: UUID? = nil) -> Run {
    Run(date: Date(timeIntervalSince1970: 1_800_000_000), projectPath: "/p/debian", playbook: playbook, version: "abc123",
        hosts: results.isEmpty ? ["alpha", "beta"] : results.map(\.host), checkMode: check, exitCode: 0, cancelled: cancelled,
        results: results, log: ["PLAY [all] ***", "secret-looking line"], batchID: batch, options: options)
}

@Suite struct RunExportTests {
    @Test func batchSummaryText() {
        let runs = [run("a.yml", [result("h1"), result("h2"), result("h3")]),
                    run("b.yml", [result("h1"), result("h4"), result("h5", unreachable: 1)]),
                    run("c.yml", [result("h2"), result("h6", failed: 1)])]
        let s = RunExport.batchSummary(projectName: "debian", check: true, runs: runs, cancelled: false)
        #expect(s.title == "debian — simulation")
        #expect(s.body == "3 playbooks, 4/6 machines en succès")
        let one = RunExport.batchSummary(projectName: "p", check: false, runs: [run("a.yml", [result("h1")])], cancelled: false)
        #expect(one.title == "p — déploiement réel" && one.body == "1 playbook, 1/1 machine en succès")
        #expect(RunExport.batchSummary(projectName: "p", check: true, runs: [], cancelled: true).body == "annulé")
        #expect(RunExport.batchSummary(projectName: "p", check: true, runs: runs, cancelled: true).body == "annulé après 3 playbooks")
        #expect(RunExport.batchSummary(projectName: "p", check: true, runs: [], cancelled: false).body == "aucun playbook lancé")
    }

    @Test func csvEscapingAndFormulas() {
        #expect(RunExport.csvField("plain") == "plain")
        #expect(RunExport.csvField("a,b") == "\"a,b\"")
        #expect(RunExport.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(RunExport.csvField("l1\nl2") == "\"l1\nl2\"")
        #expect(RunExport.csvField("l1\r\nl2") == "\"l1\r\nl2\"")
        #expect(RunExport.csvField("=1+1") == "'=1+1")
        #expect(RunExport.csvField("+cmd") == "'+cmd")
        #expect(RunExport.csvField("-e x") == "'-e x")
        #expect(RunExport.csvField("@SUM(A1)") == "'@SUM(A1)")
        #expect(RunExport.csvField("=HYPERLINK(\"x\",\"y\")") == "\"'=HYPERLINK(\"\"x\"\",\"\"y\"\")\"")
        #expect(RunExport.csvField("") == "")
    }

    @Test func csvOneLinePerMachine() {
        var options = DeployOptions(); options.tags = "web,db"
        let batch = UUID()
        let csv = RunExport.csv([run("site.yml", [result("alpha"), result("beta", failed: 1)], check: false, options: options, batch: batch),
                                 run("x.yml", [], cancelled: true)])
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.last == "")  // trailing CRLF
        #expect(lines[0] == RunExport.csvHeader.joined(separator: ","))
        #expect(lines[0] == "date,projet,playbook,hash,mode,machine,statut,ok,changed,unreachable,failed,skipped,batchID,options")
        #expect(lines[1] == "2027-01-15T08:00:00Z,debian,site.yml,abc123,réel,alpha,success,2,1,0,0,0,\(batch.uuidString),\"'--tags web,db\"")
        #expect(lines[2].contains(",beta,failed,2,1,0,1,0,"))
        #expect(lines[3] == "2027-01-15T08:00:00Z,debian,x.yml,abc123,simulation,alpha,annulé,,,,,,,")
        #expect(lines.count == 6)
        #expect(!csv.contains("PLAY [all]"))  // no log in CSV
    }

    @Test func jsonRoundTripWithAndWithoutLogs() throws {
        let runs = [run("site.yml", [result("alpha")]), run("x.yml", [], cancelled: true)]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let full = try dec.decode([Run].self, from: RunExport.json(runs, includeLogs: true))
        #expect(full == runs)
        let light = try dec.decode([Run].self, from: RunExport.json(runs))
        #expect(light.allSatisfy { $0.log.isEmpty })
        #expect(light.map { var r = $0; r.log = runs[0].log; return r } == runs)
    }

    @Test func exportWrittenToTempFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RunExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("h.csv")
        try RunExport.csv([run("site.yml", [result("alpha")])]).write(to: url, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("date,projet"))
    }
}
