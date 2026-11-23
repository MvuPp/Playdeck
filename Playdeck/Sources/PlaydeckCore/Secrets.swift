import Foundation
import Security

/// Passwords for one run. Deliberately not Codable: kept in memory only, never in `DeployOptions` / `Run`.
public struct DeploySecrets: Sendable, Equatable {
    /// ansible-vault password (from the Keychain); nil or "" = none.
    public var vaultPassword: String?
    /// become (sudo) password typed at confirmation; nil or "" = none.
    public var becomePassword: String?

    public init(vaultPassword: String? = nil, becomePassword: String? = nil) {
        self.vaultPassword = vaultPassword
        self.becomePassword = becomePassword
    }

    /// The project's vault password from `store` (account = project path) + the typed become password.
    public init(project path: String, store: any PasswordStore, becomePassword: String? = nil) {
        self.init(vaultPassword: store.password(for: path), becomePassword: becomePassword)
    }

    public var isEmpty: Bool { (vaultPassword ?? "").isEmpty && (becomePassword ?? "").isEmpty }
}

/// `--vault-password-file` / `--become-password-file` for one ansible-playbook process. Ansible runs an executable
/// password file and reads its stdout, so each file is a script that holds NO secret: it prints an environment
/// variable that is set only on that ansible-playbook process (`environment`). Scripts live in a fresh 0700 dir
/// under the user's temp dir; `remove()` deletes it (called when the process ends).
public struct SecretScripts: Sendable {
    public static let vaultVariable = "PLAYDECK_VAULT_PASSWORD"
    public static let becomeVariable = "PLAYDECK_BECOME_PASSWORD"

    public let directory: URL
    /// Extra ansible-playbook arguments (file paths only).
    public let arguments: [String]
    /// Secrets to pass to the ansible-playbook process only.
    public let environment: [String: String]

    public init(_ secrets: DeploySecrets, in parent: URL = FileManager.default.temporaryDirectory) throws {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent("playdeck-secrets-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var args: [String] = [], env: [String: String] = [:]
        for (flag, variable, value) in [("--vault-password-file", Self.vaultVariable, secrets.vaultPassword),
                                        ("--become-password-file", Self.becomeVariable, secrets.becomePassword)] {
            guard let value, !value.isEmpty else { continue }
            let script = dir.appendingPathComponent(String(flag.dropFirst(2)))
            let body = "#!/bin/sh\nprintf '%s' \"$\(variable)\"\n"
            guard fm.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
                try? fm.removeItem(at: dir)
                throw StatusError(message: "Impossible de créer le script de mot de passe dans \(dir.path)")
            }
            args += [flag, script.path]
            env[variable] = value
        }
        (directory, arguments, environment) = (dir, args, env)
    }

    public func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Where per-project vault passwords live. `Keychain` in the app; tests inject an in-memory store.
public protocol PasswordStore: Sendable {
    func password(for account: String) -> String?
    /// Whether a password is stored, without reading it.
    func hasPassword(for account: String) -> Bool
    /// nil or "" deletes it.
    func setPassword(_ password: String?, for account: String) throws
}

/// macOS Keychain (generic passwords, service "Playdeck", account = project path).
public struct Keychain: PasswordStore {
    public let service: String
    public init(service: String = "Playdeck") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func password(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func hasPassword(for account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func setPassword(_ password: String?, for account: String) throws {
        let deleted = SecItemDelete(query(account) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Self.error(deleted) }
        guard let password, !password.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "Playdeck — mot de passe ansible-vault"
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.error(added) }
    }

    private static func error(_ status: OSStatus) -> StatusError {
        StatusError(message: "Trousseau : " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "erreur \(status)"))
    }
}
