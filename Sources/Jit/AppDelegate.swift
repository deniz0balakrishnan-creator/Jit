import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let chime = Chime()
    private var pet: Pet!
    private var server: NotifyServer!
    private var statusItem: NSStatusItem!
    /// The app each tool last ran in (Claude.app, the Codex app, a terminal…), to open from the bubble.
    private var hostApps: [Tool: URL] = [:]
    private static let defaultApps: [Tool: String] = [.claude: "com.anthropic.claudefordesktop", .codex: "com.openai.codex"]
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["volume": 0.7])
        chime.volume = defaults.float(forKey: "volume")

        pet = Pet(sprite: Sprite.load())
        pet.onChime = { [chime] in chime.play() }
        pet.onPick = { [weak self] tool in self?.open(tool) }

        server = NotifyServer { [weak self] message in self?.handle(message) }
        server.start()

        buildMenu()

        // Start at login is on by default: register once, then respect the user's choice.
        if !defaults.bool(forKey: "loginDefaultApplied") {
            defaults.set(true, forKey: "loginDefaultApplied")
            try? SMAppService.mainApp.register()
        }

        if !defaults.bool(forKey: "askedToInstallHooks") {
            defaults.set(true, forKey: "askedToInstallHooks")
            askToInstallHooks()
        }
    }

    // MARK: Messages from the jit helper

    private func handle(_ message: [String: Any]) {
        guard let name = message["tool"] as? String, let tool = Tool(rawValue: name) else { return }
        let event = message["event"] as? String ?? "finished"
        let session = message["session"] as? String ?? "manual"
        NSLog("Jit: %@ %@", tool.displayName, event)
        // The first regular app among the hook's parent processes is where the tool runs.
        if let pids = message["pids"] as? [Int],
           let app = pids.lazy.compactMap({ NSRunningApplication(processIdentifier: pid_t($0)) })
               .first(where: { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }),
           let url = app.bundleURL {
            hostApps[tool] = url
        }
        switch event {
        case "working": pet.setWorking(tool, session: session, true)
        case "idle": pet.setWorking(tool, session: session, false)
        default: pet.finished(tool, session: session)
        }
    }

    /// Brings up the app the tool last ran in, or opens its default app.
    private func open(_ tool: Tool) {
        let url = hostApps[tool] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.defaultApps[tool]!)
        guard let url else {
            alert("Couldn't find \(tool.displayName)", "Jit didn't find an app for \(tool.displayName). Run a task in it once and Jit will remember where it runs.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Art.menuIcon
        statusItem.button?.toolTip = "Jit"

        let menu = NSMenu()
        menu.autoenablesItems = false
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(volumeItem())
        menu.addItem(item("Test Finish", #selector(testFinish)))
        menu.addItem(.separator())
        menu.addItem(item("Install Hooks…", #selector(installHooks)))
        menu.addItem(item("Remove Hooks…", #selector(removeHooks)))
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Jit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func volumeItem() -> NSMenuItem {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)!)
        let high = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)!)
        let slider = NSSlider(value: Double(chime.volume), minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged))
        slider.setAccessibilityLabel("Chime volume")
        for view in [low, high] { view.contentTintColor = .secondaryLabelColor }
        low.frame = NSRect(x: 18, y: 7, width: 16, height: 16)
        slider.frame = NSRect(x: 38, y: 5, width: 140, height: 20)
        high.frame = NSRect(x: 182, y: 7, width: 22, height: 16)
        [low, slider, high].forEach(row.addSubview)
        let item = NSMenuItem()
        item.view = row
        return item
    }

    @objc private func togglePause() {
        pet.setPaused(!pet.paused)
        pauseItem.title = pet.paused ? "Resume" : "Pause"
        statusItem.button?.appearsDisabled = pet.paused
    }

    @objc private func volumeChanged(_ slider: NSSlider) {
        chime.volume = slider.floatValue
        defaults.set(slider.floatValue, forKey: "volume")
    }

    @objc private func testFinish() {
        pet.finish([.claude, .codex])
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Start at Login", error.localizedDescription)
        }
    }

    // MARK: Hooks

    private func askToInstallHooks() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Install hooks for Claude Code and Codex?"
        alert.informativeText = "Jit adds a Stop hook to ~/.claude/settings.json and ~/.codex/config.toml so it chimes when either one finishes. Each file is backed up first. You can do this later from the Jit menu."
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { installHooks() }
    }

    @objc private func installHooks() {
        alert("Install Hooks", HookInstaller.install().joined(separator: "\n\n"))
    }

    @objc private func removeHooks() {
        alert("Remove Hooks", HookInstaller.remove().joined(separator: "\n\n"))
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
