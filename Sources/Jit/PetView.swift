import AppKit

/// Draws the squid at 4× with nearest-neighbour scaling, and runs his animations.
///
/// Layers: root → bodyLayer (its mask hides all but the bottom rows when tucked)
///         → spriteLayer (bob, hop, squash and stretch) and marksLayer (tool marks above his head).
final class PetView: NSView {
    static let scale: CGFloat = 4
    static let spriteSide = CGFloat(Sprite.size) * scale  // 128 pt
    static let size = NSSize(width: 168, height: 212)     // room for the hop and the marks
    static let tuckedRowsShown: CGFloat = 6
    static let hopHeight: CGFloat = 30
    static let hopDuration: CFTimeInterval = 0.5

    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    private let sprite: Sprite
    private let tuckMask = CALayer()
    private let bodyLayer = CALayer()
    private let spriteLayer = CALayer()
    private let marksLayer = CALayer()
    private var tucked = false
    private var showingMarks = false
    private var pendingClick: DispatchWorkItem?
    private var blinkTimer: Timer?

    init(sprite: Sprite) {
        self.sprite = sprite
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true

        bodyLayer.frame = bounds
        tuckMask.backgroundColor = NSColor.black.cgColor
        tuckMask.anchorPoint = CGPoint(x: 0.5, y: 0)
        tuckMask.bounds = bounds
        tuckMask.position = CGPoint(x: bounds.midX, y: 0)
        bodyLayer.mask = tuckMask
        spriteLayer.contents = sprite.open
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: Self.spriteSide, height: Self.spriteSide)
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)  // squash and stretch from his feet
        spriteLayer.position = CGPoint(x: bounds.midX, y: 0)
        marksLayer.frame = CGRect(x: 0, y: Self.spriteSide + 8, width: bounds.width, height: 9 * 3)
        marksLayer.isHidden = true

        layer!.addSublayer(bodyLayer)
        bodyLayer.addSublayer(spriteLayer)
        bodyLayer.addSublayer(marksLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Jit")

        startIdle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Idle: a slow one-pixel bob and a blink every 3 to 5 seconds

    /// The bob stretches him one pixel taller from his feet, so his tentacle tips stay gripping the edge.

    private func startIdle() {
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let bob = CAKeyframeAnimation(keyPath: "transform.scale.y")
            bob.values = [1, (Self.spriteSide + Self.scale) / Self.spriteSide]  // exactly one sprite pixel
            bob.keyTimes = [0, 0.5, 1]
            bob.calculationMode = .discrete
            bob.duration = 2.4
            bob.repeatCount = .infinity
            spriteLayer.add(bob, forKey: "bob")
        }
        scheduleBlink()
    }

    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 3...5), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.setContents(self.sprite.blink)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.setContents(self.sprite.open)
                self.scheduleBlink()
            }
        }
    }

    private func setContents(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = image
        CATransaction.commit()
    }

    // MARK: Poses

    func setTucked(_ tucked: Bool, animated: Bool) {
        guard tucked != self.tucked else { return }
        self.tucked = tucked
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: tucked ? .easeIn : .easeOut))
        CATransaction.setDisableActions(!animated)
        tuckMask.bounds.size.height = tucked ? Self.tuckedRowsShown * Self.scale : bounds.height
        CATransaction.commit()
    }

    /// Rises about 30 pt with squash and stretch, then settles into perched.
    /// From tucked, he first unfolds into view.
    func hop() {
        let delay: CFTimeInterval = tucked ? 0.25 : 0
        setTucked(false, animated: true)
        let times: [NSNumber] = [0, 0.12, 0.42, 0.7, 0.84, 1]
        let up = CAMediaTimingFunction(name: .easeOut), down = CAMediaTimingFunction(name: .easeIn)
        let linear = CAMediaTimingFunction(name: .linear)
        let curves = [linear, up, down, linear, up]
        func track(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = values
            a.keyTimes = times
            a.timingFunctions = curves
            return a
        }
        let hop = CAAnimationGroup()
        hop.animations = [
            track("transform.translation.y", [0, 0, Self.hopHeight, 0, 0, 0]),
            track("transform.scale.x", [1, 1.12, 0.92, 1, 1.18, 1]),  // crouch, stretch, land squash
            track("transform.scale.y", [1, 0.86, 1.1, 1, 0.8, 1]),
        ]
        hop.duration = Self.hopDuration
        hop.beginTime = CACurrentMediaTime() + delay
        hop.fillMode = .backwards
        spriteLayer.add(hop, forKey: "hop")
    }

    /// A small squash when he's clicked back down to perched.
    func settle() {
        let squash = CAKeyframeAnimation(keyPath: "transform.scale.y")
        squash.values = [1, 0.9, 1]
        squash.duration = 0.18
        spriteLayer.add(squash, forKey: "settle")
    }

    /// Shows one mark per tool, in order. `delay` lets a hop land first.
    func setMarks(_ marks: [Tool], delay: TimeInterval = 0) {
        let images = marks.map { $0 == .claude ? Art.claudeMark : Art.codexMark }
        showingMarks = !images.isEmpty
        let side: CGFloat = 9 * 3, gap: CGFloat = 6
        let total = CGFloat(images.count) * side + CGFloat(max(images.count - 1, 0)) * gap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marksLayer.sublayers = images.enumerated().map { i, image in
            let mark = CALayer()
            mark.contents = image
            mark.magnificationFilter = .nearest
            mark.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(i) * (side + gap), y: 0, width: side, height: side)
            return mark
        }
        marksLayer.isHidden = true
        CATransaction.commit()
        setAccessibilityLabel(marks.isEmpty ? "Jit" : "Jit: " + marks.map(\.displayName).joined(separator: " and ") + " finished")

        guard showingMarks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.showingMarks else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.marksLayer.isHidden = false
            CATransaction.commit()
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.6
            pop.toValue = 1
            pop.duration = 0.2
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.marksLayer.add(pop, forKey: "pop")
        }
    }

    // MARK: Clicks: only opaque squid pixels (and the marks) count as him

    func isOnPet(_ point: NSPoint) -> Bool {
        if showingMarks && !marksLayer.isHidden && marksLayer.frame.contains(point) { return true }
        if tucked && point.y >= Self.tuckedRowsShown * Self.scale { return false }
        let col = Int(floor((point.x - (bounds.midX - Self.spriteSide / 2)) / Self.scale))
        let row = Sprite.size - 1 - Int(floor(point.y / Self.scale))
        return point.y >= 0 && sprite.isOpaque(col: col, row: row)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isOnPet(convert(event.locationInWindow, from: nil)) else { return }
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
            onDoubleClick()
        } else {
            // Wait to see whether this becomes a double-click.
            let click = DispatchWorkItem { [weak self] in self?.onClick() }
            pendingClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
        }
    }
}
