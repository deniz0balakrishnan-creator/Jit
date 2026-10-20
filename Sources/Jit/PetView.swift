import AppKit

/// Draws the squid at 4× with nearest-neighbour scaling, and runs his animations.
///
/// Poses:
/// - peeking (idle): he hangs below the screen's bottom edge, his head and eyes peeking
///   over it and two tentacle paws gripping it;
/// - thinking: risen a little out of the peek, a tentacle on his chin and a thought bubble
///   at his top right holding the Claude and/or Codex icons;
/// - up (a task finished): he jumps out and floats just above the edge, bobbing, with the
///   tool marks over his head.
///
/// Layers: root (clips at the screen edge) → pawLayer, and bodyLayer (moves between the poses)
///         → floatLayer (float bob) → spriteLayer (blink, peek bob, squash and stretch),
///           marksLayer, and bubbleLayer (trail dots and the bubble).
final class PetView: NSView {
    static let scale: CGFloat = 4
    static let spriteSide = CGFloat(Sprite.size) * scale  // 128 pt
    static let size = NSSize(width: 168, height: 200)     // room for the jump, the bob, the marks and the bubble
    static let floatHeight: CGFloat = 10                  // his feet, above the edge, while up
    static let jumpDuration: CFTimeInterval = 0.6
    private static let markScale: CGFloat = 3

    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onPick: (Tool) -> Void = { _ in }

    private let sprite: Sprite
    private let pawLayer = CALayer()
    private let bodyLayer = CALayer()
    private let floatLayer = CALayer()
    private let spriteLayer = CALayer()
    private let marksLayer = CALayer()
    private let bubbleLayer = CALayer()
    private let bubbleImage = CALayer()
    private let dotLayers = Art.bubbleDots.map { image -> CALayer in
        let dot = CALayer()
        dot.contents = image
        dot.magnificationFilter = .nearest
        return dot
    }
    private(set) var isUp = false
    private var showingMarks = false
    /// The tools shown in the thought bubble, or nil when he isn't thinking.
    private var thinking: [Tool]?
    private var pendingClick: DispatchWorkItem?
    private var blinkTimer: Timer?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Body offsets for the poses: peeking hides everything below the peek rows.
    private var peekY: CGFloat { -CGFloat(Sprite.size - sprite.peekRows) * Self.scale }
    private var restY: CGFloat { peekY + (thinking == nil ? 0 : CGFloat(Sprite.thinkRise) * Self.scale) }
    private var upY: CGFloat { Self.floatHeight }

    init(sprite: Sprite) {
        self.sprite = sprite
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer!.masksToBounds = true  // the window's bottom is the screen's bottom edge

        pawLayer.magnificationFilter = .nearest
        setPaws(sprite.paws)

        bodyLayer.frame = bounds
        floatLayer.frame = bounds
        spriteLayer.contents = sprite.open
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: Self.spriteSide, height: Self.spriteSide)
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)  // squash and stretch from his feet
        spriteLayer.position = CGPoint(x: bounds.midX, y: 0)
        marksLayer.frame = CGRect(x: 0, y: Self.spriteSide + 8, width: bounds.width, height: 9 * Self.markScale)
        marksLayer.isHidden = true
        bubbleLayer.frame = bounds
        bubbleLayer.isHidden = true
        bubbleImage.magnificationFilter = .nearest
        dotLayers.forEach(bubbleLayer.addSublayer)
        bubbleLayer.addSublayer(bubbleImage)

        layer!.addSublayer(bodyLayer)
        layer!.addSublayer(pawLayer)  // in front: the paws hold the edge
        bodyLayer.addSublayer(floatLayer)
        bodyLayer.addSublayer(bubbleLayer)
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

    private func moveBody(to y: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunctionName) {
        let from = bodyLayer.presentation()?.position.y ?? bodyLayer.position.y
        setBodyY(y)
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = from
        move.toValue = bounds.midY + y
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: timing)
        bodyLayer.add(move, forKey: "jump")
    }

    private func setPaws(_ overlay: Overlay) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pawLayer.contents = overlay.image
        let size = CGSize(width: CGFloat(Sprite.overlayWidth) * Self.scale, height: CGFloat(overlay.rows) * Self.scale)
        pawLayer.frame = CGRect(x: bounds.midX - size.width / 2, y: 0, width: size.width, height: size.height)
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
        let from = isUp ? upY : restY
        isUp = true
        spriteLayer.removeAnimation(forKey: "peekBob")
        setPawsVisible(false)
        setBubbleVisible(false)
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

    /// Drops back below the edge, into the peek or the thinking pose.
    func dropDown() {
        guard isUp else { return }
        isUp = false
        floatLayer.removeAllAnimations()
        moveBody(to: restY, duration: 0.3, timing: .easeIn)
        setPaws(thinking == nil ? sprite.paws : sprite.thinkingPaws)
        setPawsVisible(true, delay: 0.25)
        if thinking == nil { startPeekBob() } else { setBubbleVisible(true, delay: 0.3) }
    }

    /// Thinking pose with a bubble holding `tools`, or back to the plain peek for nil.
    /// `busy` animates the bubble's trail dots, to show a task is being worked on.
    func setThinking(_ tools: [Tool]?, busy: Bool) {
        let wasThinking = thinking != nil
        thinking = tools
        if let tools { layoutBubble(tools, busy: busy) }
        guard !isUp else { return }  // shown when he drops back down
        if tools != nil && !wasThinking {
            spriteLayer.removeAnimation(forKey: "peekBob")  // keep his chin on the tentacle
            setPaws(sprite.thinkingPaws)
            moveBody(to: restY, duration: 0.25, timing: .easeOut)
            setBubbleVisible(true, delay: 0.15)
        } else if tools == nil && wasThinking {
            setBubbleVisible(false)
            setPaws(sprite.paws)
            moveBody(to: restY, duration: 0.2, timing: .easeIn)
            startPeekBob()
        }
    }

    /// Lays the bubble out at the top right of his head; the trail dots climb from his head to it.
    private func layoutBubble(_ tools: [Tool], busy: Bool) {
        let s = Self.markScale
        let headTop = Self.spriteSide - CGFloat(sprite.headTop.row) * Self.scale
        let headRight = bounds.midX - Self.spriteSide / 2 + CGFloat(sprite.headTop.rightCol + 1) * Self.scale
        let size = CGSize(width: CGFloat(Art.bubbleWidth(icons: tools.count)) * s, height: CGFloat(Art.bubbleHeight) * s)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayers[0].frame = CGRect(x: headRight - 6, y: headTop + 2, width: 4 * s, height: 4 * s)
        dotLayers[1].frame = CGRect(x: headRight + 2, y: headTop + 14, width: 5 * s, height: 5 * s)
        bubbleImage.contents = Art.thoughtBubble(tools)
        bubbleImage.frame = CGRect(x: min(bounds.width - 4 - size.width, headRight - 16), y: headTop + 29,
                                   width: size.width, height: size.height)
        CATransaction.commit()
        setAccessibilityLabel("Jit: " + tools.map(\.displayName).joined(separator: " or ") + (busy ? " working" : ""))

        for (i, dot) in dotLayers.enumerated() {
            dot.removeAnimation(forKey: "think")
            guard busy && !reduceMotion else { continue }
            // The dots light up one after the other, like a thought forming.
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.2, 1, 1, 0.2]
            pulse.keyTimes = [0, 0.15, 0.7, 1]
            pulse.duration = 1.2
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.3
            pulse.fillMode = .backwards
            dot.add(pulse, forKey: "think")
        }
    }

    private func setBubbleVisible(_ visible: Bool, delay: CFTimeInterval = 0) {
        let show = { [weak self] in
            guard let self, visible == (self.thinking != nil && !self.isUp) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.bubbleLayer.isHidden = !visible
            CATransaction.commit()
            guard visible else { return }
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.7
            pop.toValue = 1
            pop.duration = 0.18
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.bubbleImage.add(pop, forKey: "pop")
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: show) } else { show() }
    }

    /// Shows one mark per tool, in order, once he's up. `delay` lets a jump land first.
    func setMarks(_ marks: [Tool], delay: TimeInterval = 0) {
        let images = marks.map(Art.mark)
        showingMarks = !images.isEmpty
        let side = 9 * Self.markScale, gap: CGFloat = 6
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
        if !marks.isEmpty {
            setAccessibilityLabel("Jit: " + marks.map(\.displayName).joined(separator: " and ") + " finished")
        }

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

    // MARK: Clicks: only his visible pixels (paws, marks and bubble included) count as him

    /// The tool whose icon in the thought bubble is under `point`, if any.
    private func bubbleTool(at point: NSPoint) -> Tool? {
        guard let tools = thinking, !isUp, !bubbleLayer.isHidden, let root = layer?.presentation() ?? layer else { return nil }
        let bubble = bubbleImage.presentation() ?? bubbleImage
        let p = bubble.convert(point, from: root)
        let cell = 11 * Self.markScale
        guard bubble.bounds.contains(p) else { return nil }
        let i = Int((p.x - 2 * Self.markScale) / cell)
        return tools.indices.contains(i) ? tools[i] : nil
    }

    func isOnPet(_ point: NSPoint) -> Bool {
        guard bounds.contains(point), let root = layer?.presentation() ?? layer else { return false }
        if !isUp {
            let overlay = thinking == nil ? sprite.paws : sprite.thinkingPaws
            let p = pawLayer.convert(point, from: layer)
            let col = Int(floor(p.x / Self.scale)), row = overlay.rows - 1 - Int(floor(p.y / Self.scale))
            if overlay.isOpaque(col: col, row: row) { return true }
            let bubble = bubbleImage.presentation() ?? bubbleImage
            if thinking != nil && !bubbleLayer.isHidden && bubble.convert(bubble.bounds, to: root).contains(point) { return true }
        }
        let marks = marksLayer.presentation() ?? marksLayer
        if showingMarks && !marksLayer.isHidden && marks.convert(marks.bounds, to: root).contains(point) { return true }
        let p = (spriteLayer.presentation() ?? spriteLayer).convert(point, from: root)
        let col = Int(floor(p.x / Self.scale)), row = Sprite.size - 1 - Int(floor(p.y / Self.scale))
        return sprite.isOpaque(col: col, row: row)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let tool = bubbleTool(at: point) {
            onPick(tool)
            return
        }
        guard isOnPet(point) else { return }
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
