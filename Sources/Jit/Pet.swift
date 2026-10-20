import AppKit

enum Tool: String {
    case claude, codex
    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

/// Jit's behaviour: where he sits, when he's tucked, hops, marks, and pause.
final class Pet {
    var onChime: () -> Void = {}

    private(set) var paused = false
    private let window: NSPanel
    private let view: PetView
    private var userTucked = UserDefaults.standard.bool(forKey: "tucked") {
        didSet { UserDefaults.standard.set(userTucked, forKey: "tucked") }
    }
    private var fullscreen = false
    private var marks: [Tool] = []
    private var finishedWhilePaused: [Tool] = []
    private var hopWhenFullscreenEnds = false
    private var timers: [Timer] = []

    private var tucked: Bool { fullscreen || userTucked }

    init(sprite: Sprite) {
        view = PetView(sprite: sprite)
        window = NSPanel(contentRect: NSRect(origin: .zero, size: PetView.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = view

        view.onClick = { [weak self] in self?.dismiss() }
        view.onDoubleClick = { [weak self] in self?.toggleTucked() }

        fullscreen = Self.fullscreenAppIsActive()
        view.setTucked(tucked, animated: false)
        place()
        window.orderFrontRegardless()

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
        }
    }

    private func reveal(_ tools: [Tool]) {
        add(tools, to: &marks)
        userTucked = false
        if fullscreen {
            hopWhenFullscreenEnds = true
        } else {
            view.hop()
            view.setMarks(marks, delay: PetView.hopDuration + 0.25)
        }
    }

    /// Click: clear the marks and drop back to perched.
    private func dismiss() {
        guard !marks.isEmpty else { return }
        marks = []
        view.setMarks([])
        view.settle()
    }

    /// Double-click: toggle tucked and up.
    private func toggleTucked() {
        guard !fullscreen else { return }
        userTucked.toggle()
        marks = []
        view.setMarks([])
        view.setTucked(userTucked, animated: true)
        updatePassThrough()
    }

    private func checkFullscreen() {
        let now = Self.fullscreenAppIsActive()
        guard now != fullscreen else { return }
        fullscreen = now
        place()
        if fullscreen {
            view.setMarks([])
            view.setTucked(true, animated: true)
        } else if hopWhenFullscreenEnds {
            hopWhenFullscreenEnds = false
            view.hop()
            view.setMarks(marks, delay: PetView.hopDuration + 0.25)
        } else {
            view.setTucked(tucked, animated: true)
            view.setMarks(marks)
        }
    }

    // MARK: Helpers

    private func add(_ tools: [Tool], to list: inout [Tool]) {
        for tool in tools where !list.contains(tool) { list.append(tool) }
    }

    /// Bottom-right of the primary screen: on top of the Dock normally, on the very edge in fullscreen.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let bottom = fullscreen ? screen.frame.minY : screen.visibleFrame.minY
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - PetView.size.width - 24, y: bottom))
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
