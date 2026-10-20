import AppKit

/// Draws the squid at 4× with nearest-neighbour scaling, and runs his animations.
///
/// Two poses:
/// - peeking (inactive): he hangs below the screen's bottom edge, his head and eyes peeking
///   over it and two tentacle paws gripping it;
/// - up (a task finished): he jumps out and floats just above the edge, bobbing, with the
///   tool marks over his head.
///
/// Layers: root (clips at the screen edge) → pawLayer, and bodyLayer (moves between the poses)
///         → floatLayer (float bob) → spriteLayer (blink, peek bob, squash and stretch) and marksLayer.
final class PetView: NSView {
    static let scale: CGFloat = 4
    static let spriteSide = CGFloat(Sprite.size) * scale  // 128 pt
    static let size = NSSize(width: 168, height: 200)     // room for the jump, the bob and the marks
    static let floatHeight: CGFloat = 10                  // his feet, above the edge, while up
    static let jumpDuration: CFTimeInterval = 0.6

    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    private let sprite: Sprite
    private let pawLayer = CALayer()
    private let bodyLayer = CALayer()
    private let floatLayer = CALayer()
    private let spriteLayer = CALayer()
    private let marksLayer = CALayer()
    private(set) var isUp = false
    private var showingMarks = false
    private var pendingClick: DispatchWorkItem?
    private var blinkTimer: Timer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Body offsets for the two poses: peeking hides everything below the peek rows.
    private var peekY: CGFloat { -CGFloat(Sprite.size - sprite.peekRows) * Self.scale }
    private var upY: CGFloat { Self.floatHeight }

    init(sprite: Sprite) {
        self.sprite = sprite
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer!.masksToBounds = true  // the window's bottom is the screen's bottom edge

        let pawsSize = CGSize(width: CGFloat(Sprite.pawsWidth) * Self.scale, height: 3 * Self.scale)
        pawLayer.contents = sprite.paws
        pawLayer.magnificationFilter = .nearest
        pawLayer.frame = CGRect(x: bounds.midX - pawsSize.width / 2, y: 0, width: pawsSize.width, height: pawsSize.height)

        bodyLayer.frame = bounds
        floatLayer.frame = bounds
        spriteLayer.contents = sprite.open
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: Self.spriteSide, height: Self.spriteSide)
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)  // squash and stretch from his feet
        spriteLayer.position = CGPoint(x: bounds.midX, y: 0)
        marksLayer.frame = CGRect(x: 0, y: Self.spriteSide + 8, width: bounds.width, height: 9 * 3)
        marksLayer.isHidden = true

        layer!.addSublayer(bodyLayer)
        layer!.addSublayer(pawLayer)  // in front: the paws hold the edge
        bodyLayer.addSublayer(floatLayer)
        floatLayer.addSublayer(spriteLayer)
        floatLayer.addSublayer(marksLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Jit")

        setBodyY(peekY)
        startPeekBob()
        scheduleBlink()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Idle

    /// While peeking he rises one pixel now and then, as if taking a look.
    private func startPeekBob() {
        guard !reduceMotion else { return }
        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = [0, Self.scale]  // whole sprite pixels keep him crisp
        bob.keyTimes = [0, 0.6, 1]
        bob.calculationMode = .discrete
        bob.duration = 3
        bob.repeatCount = .infinity
        spriteLayer.add(bob, forKey: "peekBob")
    }

    /// While up he floats: a slow bob plus a gentle sideways drift.
    private func startFloating(after delay: CFTimeInterval) {
        guard !reduceMotion else { return }
        for (key, keyPath, amount, period) in [("bob", "transform.translation.y", 5.0, 1.2),
                                              ("drift", "transform.translation.x", 4.0, 1.9)] {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = -amount
            a.toValue = amount
            a.duration = period
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = CACurrentMediaTime() + delay
            a.fillMode = .backwards
            floatLayer.add(a, forKey: key)
        }
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

    private func setBodyY(_ y: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyLayer.position.y = bounds.midY + y
        CATransaction.commit()
    }

    private func setPawsVisible(_ visible: Bool, delay: CFTimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = pawLayer.presentation()?.opacity ?? pawLayer.opacity
        fade.toValue = visible ? 1 : 0
        fade.duration = 0.12
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pawLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
        pawLayer.add(fade, forKey: "fade")
    }

    /// Jumps out of the peek (or, if already up, jumps again) and settles into floating.
    func jumpUp() {
        let from = isUp ? upY : peekY
        isUp = true
        spriteLayer.removeAnimation(forKey: "peekBob")
        setPawsVisible(false)
        setBodyY(upY)

        let times: [NSNumber] = [0, 0.15, 0.55, 0.85, 1]
        let rise = CAKeyframeAnimation(keyPath: "position.y")
        rise.values = [from, from - 4, upY + 30, upY - 3, upY].map { bounds.midY + $0 }
        rise.keyTimes = times
        rise.timingFunctions = [.easeIn, .easeOut, .easeIn, .easeOut].map { CAMediaTimingFunction(name: $0) }
        rise.duration = Self.jumpDuration
        bodyLayer.add(rise, forKey: "jump")

        let squash = CAAnimationGroup()
        squash.animations = [("transform.scale.x", [1, 1.12, 0.92, 1.1, 1]),
                             ("transform.scale.y", [1, 0.86, 1.12, 0.88, 1])].map { keyPath, values in
            let a = CAKeyframeAnimation(keyPath: keyPath)
            a.values = values
            a.keyTimes = times
            return a
        }
        squash.duration = Self.jumpDuration
        spriteLayer.add(squash, forKey: "squash")

        floatLayer.removeAllAnimations()
        startFloating(after: Self.jumpDuration)
    }

    /// Drops back below the edge into the peek.
    func dropDown() {
        guard isUp else { return }
        isUp = false
        floatLayer.removeAllAnimations()
        let from = bodyLayer.presentation()?.position.y ?? bounds.midY + upY
        setBodyY(peekY)
        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = from
        fall.toValue = bounds.midY + peekY
        fall.duration = 0.3
        fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
        bodyLayer.add(fall, forKey: "jump")
        setPawsVisible(true, delay: 0.25)
        startPeekBob()
    }

    /// Shows one mark per tool, in order, once he's up. `delay` lets a jump land first.
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
            guard let self, self.showingMarks, self.isUp else { return }
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

    // MARK: Clicks: only his visible pixels (paws and marks included) count as him

    func isOnPet(_ point: NSPoint) -> Bool {
        guard bounds.contains(point), let root = layer?.presentation() ?? layer else { return false }
        if !isUp {
            let p = pawLayer.convert(point, from: layer)
            let col = Int(floor(p.x / Self.scale)), row = 2 - Int(floor(p.y / Self.scale))
            if sprite.isPawOpaque(col: col, row: row) { return true }
        }
        let marks = marksLayer.presentation() ?? marksLayer
        if showingMarks && !marksLayer.isHidden && marks.convert(marks.bounds, to: root).contains(point) { return true }
        let p = (spriteLayer.presentation() ?? spriteLayer).convert(point, from: root)
        let col = Int(floor(p.x / Self.scale)), row = Sprite.size - 1 - Int(floor(p.y / Self.scale))
        return sprite.isOpaque(col: col, row: row)
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
