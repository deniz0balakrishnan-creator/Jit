import AppKit

enum Tool: String, CaseIterable {
    case claude, codex
    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Jit's behaviour: where he sits, when he peeks, thinks or comes up, the marks, and pause.
final class Pet {
    var onChime: () -> Void = {}
    /// Called with the tool picked in the thought bubble.
    var onPick: (Tool) -> Void = { _ in }

    private(set) var paused = false
    private let window: NSPanel
    private let view: PetView
    /// Whether he should be up, out of the peek. Kept across restarts.
    private var wantsUp = UserDefaults.standard.bool(forKey: "up") {
        didSet { UserDefaults.standard.set(wantsUp, forKey: "up") }
    }
    private var fullscreen = false
    /// Entering fullscreen ducks him into the peek; a finish or a double-click brings him back up.
    private var raisedInFullscreen = false
    private var marks: [Tool] = []
    private var finishedWhilePaused: [Tool] = []
    /// Sessions that are working on a prompt right now, per tool.
    private var working: [Tool: Set<String>] = [:]
    /// The thought bubble you opened by clicking him while he was idle.
    private var choosing = false
    private var timers: [Timer] = []

    private var shouldBeUp: Bool { wantsUp && (!fullscreen || raisedInFullscreen) }
    private var busyTools: [Tool] { Tool.allCases.filter { !(working[$0]?.isEmpty ?? true) } }

    init(sprite: Sprite) {
        view = PetView(sprite: sprite)
        window = NSPanel(contentRect: NSRect(origin: .zero, size: PetView.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar  // above the Dock, whose row he shares
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = view

        view.onClick = { [weak self] in self?.click() }
        view.onDoubleClick = { [weak self] in self?.toggleUp() }
        view.onPick = { [weak self] tool in self?.pick(tool) }

        fullscreen = Self.fullscreenAppIsActive()
        place()
        window.orderFrontRegardless()
        update()

        // Clicks pass through everywhere except the squid: only accept mouse events while
        // the pointer is over one of his pixels.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.updatePassThrough() }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updatePassThrough()
            return event
        }
        window.acceptsMouseMovedEvents = true

        // macOS has no "a fullscreen app is active" API: poll window bounds once a second,
        // and also check right away when the Space changes.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkFullscreen() })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.checkFullscreen() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place() }
    }

    // MARK: Events

    /// A session started (or stopped) working on a prompt.
    func setWorking(_ tool: Tool, session: String, _ isWorking: Bool) {
        if isWorking { working[tool, default: []].insert(session) } else { working[tool]?.remove(session) }
        update()
    }

    /// A tool finished a turn: that session is no longer working.
    func finished(_ tool: Tool, session: String) {
        working[tool]?.remove(session)
        finish([tool])
    }

    /// A tool finished (or Test finish). Plays one chime for the whole batch.
    func finish(_ tools: [Tool]) {
        if paused {
            add(tools, to: &finishedWhilePaused)
            return
        }
        onChime()
        reveal(tools)
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if !paused && !finishedWhilePaused.isEmpty {
            reveal(finishedWhilePaused)  // marks appear on resume, without a chime
            finishedWhilePaused = []
        } else {
            update()
        }
    }

    /// He jumps up with the marks, in fullscreen too.
    private func reveal(_ tools: [Tool]) {
        add(tools, to: &marks)
        wantsUp = true
        raisedInFullscreen = fullscreen
        choosing = false
        update(jumpAgain: true)
    }

    /// Click: when up, clear the marks and drop back down; when idle, open or close the bubble.
    private func click() {
        if view.isUp {
            marks = []
            wantsUp = false
            raisedInFullscreen = false
        } else {
            choosing.toggle()
        }
        update()
    }

    private func pick(_ tool: Tool) {
        choosing = false
        update()
        onPick(tool)
    }

    /// Double-click: toggle peeking and up, in any Space, fullscreen ones included.
    private func toggleUp() {
        if view.isUp {
            marks = []
            wantsUp = false
            raisedInFullscreen = false
        } else {
            wantsUp = true
            raisedInFullscreen = fullscreen
        }
        choosing = false
        update()
    }

    private func checkFullscreen() {
        let now = Self.fullscreenAppIsActive()
        guard now != fullscreen else { return }
        fullscreen = now
        raisedInFullscreen = false
        update()
    }

    /// Moves him into the pose the state calls for. `jumpAgain` makes him jump even when
    /// he's already up, for a new finish.
    private func update(jumpAgain: Bool = false) {
        // Thinking: the bubble you opened offers both tools; otherwise it shows what's working.
        let busy = paused ? [] : busyTools
        view.setThinking(choosing ? Tool.allCases : (busy.isEmpty ? nil : busy), busy: !busy.isEmpty)
        if shouldBeUp && (!view.isUp || jumpAgain) {
            view.jumpUp()
            view.setMarks(marks, delay: PetView.jumpDuration)
        } else if !shouldBeUp && view.isUp {
            view.setMarks([])
            view.dropDown()
        }
        updatePassThrough()
    }

    // MARK: Helpers

    private func add(_ tools: [Tool], to list: inout [Tool]) {
        for tool in tools where !list.contains(tool) { list.append(tool) }
    }

    /// Bottom-right corner of the primary screen, flush with its bottom edge.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrameOrigin(NSPoint(x: screen.frame.maxX - PetView.size.width - 8, y: screen.frame.minY))
    }

    private func updatePassThrough() {
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        window.ignoresMouseEvents = !view.isOnPet(point)
    }

    /// True when another app's window covers the primary screen like a fullscreen window does:
    /// full width, down to the bottom edge, from the top (or from just below the camera notch).
    /// Normal windows stop at the menu bar and the Dock.
    static func fullscreenAppIsActive() -> Bool {
        guard let screen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let size = screen.frame.size  // the primary screen sits at the CG origin, y pointing down
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.minX == 0 && rect.width == size.width && rect.maxY == size.height
                && rect.minY <= screen.safeAreaInsets.top + 1
        }
    }
}
