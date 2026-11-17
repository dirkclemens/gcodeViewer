import AppKit
import SceneKit
import simd

/// SCNView subclass providing industry-standard camera navigation for a Z-up
/// print-bed scene. Used by the app window and by the interactive Quick Look
/// preview (shared with the `gcodeViewerQL` target).
///
/// Control map
/// ───────────────────────────────────────────────────────────────────────────
/// Left drag           → Orbit (turntable around world Z)
/// Right drag          → Pan (translate)
/// Shift + left drag   → Pan (translate)
/// Option + left drag  → Orbit (Maya alias)
/// Ctrl + left drag    → Dolly (zoom by camera distance)
/// Scroll wheel        → Zoom (SceneKit built-in)
/// Shift + scroll      → Pan (vertical + horizontal)
/// Ctrl + scroll       → Pan (horizontal)
///
/// F                   → Frame / reset camera
/// + / =               → Zoom in
/// − / _               → Zoom out
///
/// 1 / Numpad 1        → Front view   (+Y axis)
/// ⌘1                  → Back view    (−Y axis)
/// 3 / Numpad 3        → Right view   (+X axis)
/// ⌘3                  → Left view    (−X axis)
/// 7 / Numpad 7        → Top view     (+Z axis)
/// ⌘7                  → Bottom view  (−Z axis)
///
/// ← / →               → Pan camera left / right
/// ↑ / ↓               → Pan camera up / down
/// ⌘← / ⌘→            → Orbit left / right (15° steps)
/// ⌘↑ / ⌘↓            → Orbit up / down (15° steps)
/// ───────────────────────────────────────────────────────────────────────────
final class GCodeSCNView: SCNView {

    static let viewportBackground = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)

    private enum DragAction { case none, orbit, pan, dolly }
    private var dragAction: DragAction = .none
    private var lastDragLocation: NSPoint = .zero

    // MARK: - Setup

    /// Applies the viewport configuration shared by the app and Quick Look.
    func configureViewport() {
        allowsCameraControl = true
        defaultCameraController.interactionMode = .orbitTurntable
        // G-code is Z-up (the controller defaults to Y-up). Mouse orbiting is
        // done by this class itself; this keeps SceneKit's remaining gestures
        // (scroll zoom, trackpad) consistent with it.
        defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        autoenablesDefaultLighting = false
        antialiasingMode = .multisampling4X
        backgroundColor = Self.viewportBackground
        preferredFramesPerSecond = 60
    }

    // MARK: - Left mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        let mods = event.modifierFlags.intersection([.shift, .control])
        switch mods {
        case .shift:
            dragAction = .pan
        case .control:
            dragAction = .dolly
        default:
            // Plain drag and Option+drag both orbit. Handled here instead of by
            // SceneKit's controller, whose turntable spins around the wrong axis
            // for a Z-up scene; this uses exactly the same orbit as ⌘←/⌘→.
            dragAction = .orbit
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = event.locationInWindow
        let dx  = Float(loc.x - lastDragLocation.x)
        let dy  = Float(loc.y - lastDragLocation.y)
        lastDragLocation = loc

        switch dragAction {
        case .pan:
            panCamera(dx: dx, dy: dy)
        case .dolly:
            dollyByDrag(dy: dy)
        case .orbit:
            orbitByDrag(dx: dx, dy: dy)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragAction = .none
    }

    // MARK: - Right mouse (pan)

    override func rightMouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        dragAction = .pan
    }

    override func rightMouseDragged(with event: NSEvent) {
        let loc = event.locationInWindow
        let dx  = Float(loc.x - lastDragLocation.x)
        let dy  = Float(loc.y - lastDragLocation.y)
        lastDragLocation = loc
        panCamera(dx: dx, dy: dy)
    }

    override func rightMouseUp(with event: NSEvent) {
        dragAction = .none
    }

    // MARK: - Scroll wheel

    override func scrollWheel(with event: NSEvent) {
        let sdx  = Float(event.scrollingDeltaX)
        let sdy  = Float(event.scrollingDeltaY)
        let mods = event.modifierFlags.intersection([.shift, .control])

        switch mods {
        case .shift:
            panCamera(dx: sdx * 0.5, dy: sdy * 0.5)
        case .control:
            panCamera(dx: sdy * 0.5, dy: 0)
        default:
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let cmd  = event.modifierFlags.contains(.command)
        let code = event.keyCode

        // Arrow keys: 123=Left 124=Right 125=Down 126=Up
        if code == 123 || code == 124 || code == 125 || code == 126 {
            let panPx: Float    = 20
            let orbitRad: Float = 15 * .pi / 180
            switch code {
            case 123: cmd ? orbitStep(dAz: -orbitRad, dEl: 0)  : panCamera(dx:  panPx, dy: 0)
            case 124: cmd ? orbitStep(dAz:  orbitRad, dEl: 0)  : panCamera(dx: -panPx, dy: 0)
            case 125: cmd ? orbitStep(dAz: 0, dEl: -orbitRad)  : panCamera(dx: 0, dy:  panPx)
            case 126: cmd ? orbitStep(dAz: 0, dEl:  orbitRad)  : panCamera(dx: 0, dy: -panPx)
            default:  break
            }
            return
        }

        switch event.charactersIgnoringModifiers {

        case "f", "F":
            frameContent()

        case "+", "=":
            dollyByFraction(0.15)

        case "-", "_":
            dollyByFraction(-0.15)

        case "1":
            // Front view (+Y) or Back view (−Y) with ⌘
            setStandardView(eye: cmd ? SIMD3(0, -1, 0) : SIMD3(0, 1, 0), up: SIMD3(0, 0, 1))

        case "3":
            // Right view (+X) or Left view (−X) with ⌘
            setStandardView(eye: cmd ? SIMD3(-1, 0, 0) : SIMD3(1, 0, 0), up: SIMD3(0, 0, 1))

        case "7":
            // Top view (+Z) or Bottom view (−Z) with ⌘
            setStandardView(eye: cmd ? SIMD3(0, 0, -1) : SIMD3(0, 0, 1),
                            up:  cmd ? SIMD3(0, -1, 0) : SIMD3(0, 1, 0))

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Framing

    /// Frames everything except the reference grid from a front-above angle.
    /// Creates the camera node (with its light rig) if the view has none yet —
    /// `pointOfView` is nil after a new scene without a camera is assigned.
    func frameContent() {
        guard let scene, let (allMins, allMaxs) = Self.contentBounds(of: scene) else { return }

        let centre   = (allMins + allMaxs) * 0.5
        let radius   = simd_length(allMaxs - allMins) * 0.5
        let distance = radius * 2.5

        // Slight front-above angle for a natural initial view.
        let camPos = centre + SIMD3<Float>(0, -distance * 0.4, distance)

        let pov: SCNNode
        if let existing = pointOfView {
            pov = existing
        } else {
            pov = Self.makeCameraNode()
            scene.rootNode.addChildNode(pov)
            pointOfView = pov
        }

        // Let SceneKit fit the clipping planes to the scene every frame, so
        // the model is never cut off when zooming far out or moving in close.
        pov.camera?.automaticallyAdjustsZRange = true

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        pov.simdPosition = camPos
        pov.simdLook(at: centre, up: SIMD3<Float>(0, 0, 1), localFront: SCNNode.simdLocalFront)
        defaultCameraController.target = SCNVector3(centre.x, centre.y, centre.z)
        SCNTransaction.commit()
    }

    /// Camera with key / fill / rim lights attached, so the lighting follows the view.
    private static func makeCameraNode() -> SCNNode {
        let camNode = SCNNode()
        camNode.camera = SCNCamera()

        let key       = SCNLight()
        key.type      = .directional
        key.intensity = 900
        key.color     = NSColor.white
        let keyNode   = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 5, Float.pi / 6, 0)
        camNode.addChildNode(keyNode)

        let fill       = SCNLight()
        fill.type      = .directional
        fill.intensity = 350
        fill.color     = NSColor(white: 0.85, alpha: 1)
        let fillNode   = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        camNode.addChildNode(fillNode)

        let rim       = SCNLight()
        rim.type      = .directional
        rim.intensity = 200
        rim.color     = NSColor(white: 0.6, alpha: 1)
        let rimNode   = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(Float.pi / 6, Float.pi, 0)
        camNode.addChildNode(rimNode)

        return camNode
    }

    // MARK: - Camera manipulation

    /// Pan camera and orbit target in screen space.
    /// Positive dx → camera moves left (scene shifts right); positive dy → camera moves down.
    private func panCamera(dx: Float, dy: Float) {
        guard let pov = pointOfView else { return }
        let h = Float(bounds.height)
        guard h > 0 else { return }

        let target   = SIMD3<Float>(defaultCameraController.target)
        let distance = simd_length(SIMD3<Float>(pov.simdPosition) - target)
        let fovY     = Float(pov.camera?.fieldOfView ?? 60) * .pi / 180

        // Maps one screen pixel to world units at the target plane distance.
        let scale = 2 * distance * tan(fovY * 0.5) / h

        let right = SIMD3<Float>(pov.simdTransform.columns.0.x,
                                 pov.simdTransform.columns.0.y,
                                 pov.simdTransform.columns.0.z)
        let up    = SIMD3<Float>(pov.simdTransform.columns.1.x,
                                 pov.simdTransform.columns.1.y,
                                 pov.simdTransform.columns.1.z)

        let delta = (-right * dx - up * dy) * scale

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        pov.simdPosition += delta
        defaultCameraController.target = SCNVector3(target.x + delta.x,
                                                    target.y + delta.y,
                                                    target.z + delta.z)
        SCNTransaction.commit()
    }

    /// Move camera along its look axis. Positive fraction → zoom in (reduce distance).
    private func dollyByFraction(_ fraction: Float) {
        guard let pov = pointOfView else { return }

        let target   = SIMD3<Float>(defaultCameraController.target)
        let toTarget = target - SIMD3<Float>(pov.simdPosition)
        let distance = simd_length(toTarget)
        let step     = distance * fraction
        guard abs(step) < distance * 0.95 else { return }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        pov.simdPosition += simd_normalize(toTarget) * step
        SCNTransaction.commit()
    }

    /// Dolly driven by vertical drag. Drag up (dy > 0 in macOS window coords) → zoom in.
    private func dollyByDrag(dy: Float) {
        let h = Float(bounds.height)
        guard h > 0 else { return }
        dollyByFraction(dy * 2.0 / h)
    }

    /// Orbit driven by a mouse drag: the model follows the cursor ("grab and
    /// turn"), horizontal motion spins it around the vertical Z axis.
    private func orbitByDrag(dx: Float, dy: Float) {
        let radiansPerPixel: Float = 0.5 * .pi / 180
        orbitStep(dAz: -dx * radiansPerPixel, dEl: -dy * radiansPerPixel, animated: false)
    }

    /// Orbit the camera around the target by azimuth / elevation increments (radians).
    private func orbitStep(dAz: Float, dEl: Float, animated: Bool = true) {
        guard let pov = pointOfView else { return }

        let target = SIMD3<Float>(defaultCameraController.target)
        let offset = SIMD3<Float>(pov.simdPosition) - target
        let dist   = simd_length(offset)
        guard dist > 0 else { return }

        let az = atan2(offset.y, offset.x) + dAz
        let el = max(-.pi / 2 + 0.05,
                 min( .pi / 2 - 0.05,
                      asin(max(-1, min(1, offset.z / dist))) + dEl))

        let newOffset = SIMD3<Float>(dist * cos(el) * cos(az),
                                     dist * cos(el) * sin(az),
                                     dist * sin(el))

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.15 : 0
        pov.simdPosition = target + newOffset
        pov.simdLook(at: target, up: SIMD3<Float>(0, 0, 1), localFront: SCNNode.simdLocalFront)
        SCNTransaction.commit()
    }

    /// Position the camera on a cardinal axis framing all geometry.
    private func setStandardView(eye: SIMD3<Float>, up: SIMD3<Float>) {
        guard let scene, let pov = pointOfView else { return }

        guard let (allMins, allMaxs) = Self.contentBounds(of: scene) else { return }

        let centre = (allMins + allMaxs) * 0.5
        let d      = simd_length(allMaxs - allMins) * 0.5

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        pov.simdPosition = centre + eye * (d * 2.5)
        pov.simdLook(at: centre, up: up, localFront: SCNNode.simdLocalFront)
        defaultCameraController.target = SCNVector3(centre.x, centre.y, centre.z)
        SCNTransaction.commit()
    }

    /// World-space bounds of everything in `scene` except the reference grid.
    /// Returns nil if the scene has no geometry.
    static func contentBounds(of scene: SCNScene) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for node in scene.rootNode.childNodes {
            guard node.geometry != nil, node.name != SceneBuilder.gridNodeName else { continue }
            let (mn, mx) = node.boundingBox
            for x in [mn.x, mx.x] {
                for y in [mn.y, mx.y] {
                    for z in [mn.z, mx.z] {
                        let w = node.convertPosition(SCNVector3(x, y, z), to: nil)
                        let p = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
                        lo = simd_min(lo, p)
                        hi = simd_max(hi, p)
                    }
                }
            }
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }
}
