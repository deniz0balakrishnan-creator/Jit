import Foundation

/// Adds and removes the hooks that run `jit notify` in Claude Code (`~/.claude/settings.json`)
/// and Codex (`~/.codex/config.toml`): `Stop` for a finished turn, plus the events that tell
/// Jit a tool started working on a prompt or stopped without finishing.
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

    /// (hook event, matcher, `--event` for jit notify). nil `--event` means a finished turn.
    private static let claudeHooks: [(event: String, matcher: String?, jitEvent: String?)] = [
        ("Stop", nil, nil),
        ("UserPromptSubmit", nil, "working"),
        ("StopFailure", nil, "idle"),   // the turn ended on an API error
        ("SessionEnd", nil, "idle"),
        // Claude Code has no hook for an interrupt; this fires after a minute of waiting for input.
        ("Notification", "idle_prompt", "idle"),
    ]
    private static let codexHooks: [(event: String, jitEvent: String?)] = [
        ("Stop", nil),
        ("UserPromptSubmit", "working"),
        ("Interrupt", "idle"),
        ("SessionEnd", "idle"),
    ]

    static func command(_ tool: Tool, event: String? = nil) -> String {
        "\"\(helper.path)\" notify --tool \(tool.rawValue)" + (event.map { " --event \($0)" } ?? "")
    }

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

    // MARK: Claude Code: hooks.<Event>[] in settings.json

    private static func installClaude() throws -> String {
        guard FileManager.default.fileExists(atPath: claudeSettings.deletingLastPathComponent().path) else {
            return "not installed (no ~/.claude folder), skipped."
        }
        var settings = try readClaudeSettings()
        var hooks = try dictionary(settings["hooks"], "hooks")
        var added = 0
        for hook in claudeHooks {
            var groups = hooks[hook.event] as? [[String: Any]] ?? []
            guard !groups.contains(where: isJitGroup) else { continue }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command(.claude, event: hook.jitEvent)]]]
            if let matcher = hook.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[hook.event] = groups
            added += 1
        }
        if added == 0 { return "hooks already installed." }
        settings["hooks"] = hooks
        let backup = try write(json: settings, to: claudeSettings)
        return "hooks installed" + (backup.map { ", backup at \($0)" } ?? "") + "."
    }

    private static func removeClaude() throws -> String {
        guard FileManager.default.fileExists(atPath: claudeSettings.path) else { return "nothing to remove." }
        var settings = try readClaudeSettings()
        var hooks = try dictionary(settings["hooks"], "hooks")
        var removed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]], groups.contains(where: isJitGroup) else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
                handlers.removeAll(where: isJitHandler)
                if handlers.isEmpty { return nil }
                var group = group
                group["hooks"] = handlers
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
            removed = true
        }
        guard removed else { return "nothing to remove." }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let backup = try write(json: settings, to: claudeSettings)
        return "hooks removed" + (backup.map { ", backup at \($0)" } ?? "") + "."
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

    // MARK: Codex: [[hooks.<Event>]] blocks in config.toml, between marker comments

    private static var codexBlock: String {
        let tables = codexHooks.map { hook in
            """
            [[hooks.\(hook.event)]]

            [[hooks.\(hook.event).hooks]]
            type = "command"
            command = '\(command(.codex, event: hook.jitEvent))'
            """
        }
        return "\n" + ([tomlBegin] + tables + [tomlEnd]).joined(separator: "\n") + "\n"
    }

    private static func installCodex() throws -> String {
        guard FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) else {
            return "not installed (no ~/.codex folder), skipped."
        }
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if text.contains(codexBlock) { return "hooks already installed." }
        text = withoutCodexBlock(text) ?? text  // an older Jit block is replaced
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += codexBlock
        let backup = try write(text: text, to: codexConfig)
        return "hooks installed" + (backup.map { ", backup at \($0)" } ?? "")
            + ". Trust them in Codex: run codex and type /hooks."
    }

    private static func removeCodex() throws -> String {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8),
              let trimmed = withoutCodexBlock(text) else { return "nothing to remove." }
        let backup = try write(text: trimmed, to: codexConfig)
        return "hooks removed" + (backup.map { ", backup at \($0)" } ?? "") + "."
    }

    /// `text` with Jit's block (and the blank line before it) taken out, or nil if there is none.
    private static func withoutCodexBlock(_ text: String) -> String? {
        guard let begin = text.range(of: "\n" + tomlBegin) ?? text.range(of: tomlBegin),
              let end = text.range(of: tomlEnd + "\n", range: begin.upperBound..<text.endIndex)
                ?? text.range(of: tomlEnd, range: begin.upperBound..<text.endIndex) else { return nil }
        var trimmed = text
        trimmed.removeSubrange(begin.lowerBound..<end.upperBound)
        return trimmed
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
