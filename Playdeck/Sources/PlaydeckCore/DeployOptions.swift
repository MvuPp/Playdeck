import Foundation

/// Per-project `ansible-playbook` settings: extra vars (-e), tags, --diff, verbosity.
public struct DeployOptions: Codable, Sendable, Equatable {
    public struct Variable: Codable, Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var key: String
        public var value: String
        public init(key: String = "", value: String = "") { self.key = key; self.value = value }
    }

    public var variables: [Variable] = []
    public var tags = ""
    public var skipTags = ""
    public var diff = false
    /// 0 = normal, 1…4 = -v…-vvvv.
    public var verbosity = 0

    public init() {}

    /// Variables with a key, the last one winning on a duplicate key.
    public var extraVars: [String: String] {
        Dictionary(variables.compactMap { v in
            let k = v.key.trimmingCharacters(in: .whitespaces)
            return k.isEmpty ? nil : (k, v.value)
        }, uniquingKeysWith: { _, last in last })
    }

    /// Arguments appended to `ansible-playbook`. Variables go as ONE JSON `-e`: values with spaces, quotes or `=`
    /// survive intact (key=value would split them). Values stay strings.
    public var arguments: [String] {
        var args: [String] = []
        if !extraVars.isEmpty, let data = try? JSONSerialization.data(withJSONObject: extraVars, options: .sortedKeys) {
            args += ["-e", String(decoding: data, as: UTF8.self)]
        }
        let tags = tags.trimmingCharacters(in: .whitespaces), skip = skipTags.trimmingCharacters(in: .whitespaces)
        if !tags.isEmpty { args += ["--tags", tags] }
        if !skip.isEmpty { args += ["--skip-tags", skip] }
        if diff { args.append("--diff") }
        if verbosity > 0 { args.append("-" + String(repeating: "v", count: min(verbosity, 4))) }
        return args
    }

    public var isDefault: Bool { arguments.isEmpty }
}
