import Foundation

/// Adds and removes the `Stop` hooks that run `jit notify` in Claude Code
/// (`~/.claude/settings.json`) and Codex (`~/.codex/config.toml`).
///
/// Before changing a file it writes a timestamped backup next to it. Only Jit's own
/// entries are added or removed; everything else in the file is kept.
enum HookInstaller {
    /// A stable copy of the helper, so the hooks keep working wherever the app is built or moved.
    static let helper = NotifyServer.directory.appendingPathComponent("jit")

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    private static let codexConfig = home.appendingPathComponent(".codex/config.toml")
    private static let tomlBegin = "# >>> Jit hook (added by Jit; remove it with \"Remove hooks\" in the Jit menu)"
    private static let tomlEnd = "# <<< Jit hook"

    static func command(_ tool: Tool) -> String { "\"\(helper.path)\" notify --tool \(tool.rawValue)" }

    /// Returns one line per tool describing what happened.
    static func install() -> [String] {
        do {
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/jit")
            try FileManager.default.createDirectory(at: NotifyServer.directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: helper)
            try FileManager.default.copyItem(at: bundled, to: helper)
        } catch {
            return ["Couldn't copy the jit helper: \(error.localizedDescription)"]
        }
        return [report("Claude Code", installClaude), report("Codex", installCodex)]
    }

    static func remove() -> [String] {
        [report("Claude Code", removeClaude), report("Codex", removeCodex)]
    }

    private static func report(_ name: String, _ action: () throws -> String) -> String {
        do { return "\(name): \(try action())" } catch { return "\(name): failed, \(error.localizedDescription)" }
    }

    // MARK: Claude Code: hooks.Stop[] in settings.json

    private static func installClaude() throws -> String {
        guard FileManager.default.fileExists(atPath: claudeSettings.deletingLastPathComponent().path) else {
            return "not installed (no ~/.claude folder), skipped."
        }
        var settings = try readClaudeSettings()
        var hooks = try dictionary(settings["hooks"], "hooks")
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        if stop.contains(where: isJitGroup) { return "hook already installed." }
        stop.append(["hooks": [["type": "command", "command": command(.claude)]]])
        hooks["Stop"] = stop
        settings["hooks"] = hooks
        let backup = try write(json: settings, to: claudeSettings)
        return "hook installed" + (backup.map { ", backup at \($0)" } ?? "") + "."
    }

    private static func removeClaude() throws -> String {
        guard FileManager.default.fileExists(atPath: claudeSettings.path) else { return "nothing to remove." }
        var settings = try readClaudeSettings()
        var hooks = try dictionary(settings["hooks"], "hooks")
        guard let stop = hooks["Stop"] as? [[String: Any]], stop.contains(where: isJitGroup) else {
            return "nothing to remove."
        }
        let kept: [[String: Any]] = stop.compactMap { group in
            guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
            handlers.removeAll(where: isJitHandler)
            if handlers.isEmpty { return nil }
            var group = group
            group["hooks"] = handlers
            return group
        }
        hooks["Stop"] = kept.isEmpty ? nil : kept
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let backup = try write(json: settings, to: claudeSettings)
        return "hook removed" + (backup.map { ", backup at \($0)" } ?? "") + "."
    }

    private static func readClaudeSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: claudeSettings.path), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError("settings.json isn't a JSON object; left it unchanged")
        }
        return object
    }

    private static func dictionary(_ value: Any?, _ name: String) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let dict = value as? [String: Any] else { throw InstallError("\"\(name)\" isn't an object; left it unchanged") }
        return dict
    }

    private static func isJitHandler(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(helper.path) == true
    }

    private static func isJitGroup(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains(where: isJitHandler) == true
    }

    // MARK: Codex: a [[hooks.Stop]] block in config.toml, between marker comments

    private static func installCodex() throws -> String {
        guard FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) else {
            return "not installed (no ~/.codex folder), skipped."
        }
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if text.contains(tomlBegin) { return "hook already installed." }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += """

            \(tomlBegin)
            [[hooks.Stop]]

            [[hooks.Stop.hooks]]
            type = "command"
            command = '\(command(.codex))'
            \(tomlEnd)

            """
        let backup = try write(text: text, to: codexConfig)
        return "hook installed" + (backup.map { ", backup at \($0)" } ?? "") + "."
    }

    private static func removeCodex() throws -> String {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8),
              let begin = text.range(of: "\n" + tomlBegin) ?? text.range(of: tomlBegin),
              let end = text.range(of: tomlEnd + "\n", range: begin.upperBound..<text.endIndex)
                ?? text.range(of: tomlEnd, range: begin.upperBound..<text.endIndex) else {
            return "nothing to remove."
        }
        var trimmed = text
        trimmed.removeSubrange(begin.lowerBound..<end.upperBound)
        let backup = try write(text: trimmed, to: codexConfig)
        return "hook removed" + (backup.map { ", backup at \($0)" } ?? "") + "."
    }

    // MARK: Writing with a backup

    private static func write(json: [String: Any], to url: URL) throws -> String? {
        var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(UInt8(ascii: "\n"))
        return try write(data: data, to: url)
    }

    private static func write(text: String, to url: URL) throws -> String? {
        try write(data: Data(text.utf8), to: url)
    }

    /// Backs up the existing file (if any), then replaces it, keeping its permissions.
    /// Returns the backup's path.
    private static func write(data: Data, to url: URL) throws -> String? {
        let fm = FileManager.default
        var backup: String?
        var permissions: Any?
        if fm.fileExists(atPath: url.path) {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = URL(fileURLWithPath: url.path + ".jit-backup-" + stamp.string(from: Date()))
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
            backup = backupURL.path
            permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
        }
        try data.write(to: url, options: .atomic)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return backup
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
