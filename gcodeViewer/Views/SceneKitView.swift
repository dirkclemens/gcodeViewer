import SwiftUI
import SceneKit
import AppKit

// MARK: - Custom SCNView with complete camera controls

/// SCNView subclass providing industry-standard camera navigation.
///
/// Control map
/// ───────────────────────────────────────────────────────────────────────────
/// Left drag           → Orbit (turntable)
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

    var onResetCamera: (() -> Void)?

    private enum DragAction { case none, orbit, pan, dolly }
    private var dragAction: DragAction = .none
    private var lastDragLocation: NSPoint = .zero

    // MARK: - Left mouse

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        let mods = event.modifierFlags.intersection([.shift, .control])
        switch mods {
        case .shift:
            dragAction = .pan
        case .control:
            dragAction = .dolly
        default:
            // Plain drag and Option+drag both orbit via SceneKit's controller.
            dragAction = .orbit
            super.mouseDown(with: event)
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
            super.mouseDragged(with: event)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragAction == .orbit {
            defaultCameraController.endInteraction(event.locationInWindow,
                                                   withViewport: bounds.size,
                                                   velocity: .zero)
            super.mouseUp(with: event)
        }
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
            onResetCamera?()

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

    /// Orbit the camera around the target by azimuth / elevation increments (radians).
    private func orbitStep(dAz: Float, dEl: Float) {
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
        SCNTransaction.animationDuration = 0.15
        pov.simdPosition = target + newOffset
        pov.simdLook(at: target, up: SIMD3<Float>(0, 0, 1), localFront: pov.simdWorldFront)
        SCNTransaction.commit()
    }

    /// Position the camera on a cardinal axis framing all geometry.
    private func setStandardView(eye: SIMD3<Float>, up: SIMD3<Float>) {
        guard let scene, let pov = pointOfView else { return }

        var allMins = SIMD3<Float>( Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude)
        var allMaxs = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                                   -Float.greatestFiniteMagnitude,
                                   -Float.greatestFiniteMagnitude)
        for node in scene.rootNode.childNodes {
            guard node.geometry != nil, node.name != "grid" else { continue }
            let (mn, mx) = node.boundingBox
            let corners: [SCNVector3] = [
                SCNVector3(mn.x, mn.y, mn.z), SCNVector3(mx.x, mn.y, mn.z),
                SCNVector3(mn.x, mx.y, mn.z), SCNVector3(mx.x, mx.y, mn.z),
                SCNVector3(mn.x, mn.y, mx.z), SCNVector3(mx.x, mn.y, mx.z),
                SCNVector3(mn.x, mx.y, mx.z), SCNVector3(mx.x, mx.y, mx.z),
            ]
            for c in corners {
                let w = node.convertPosition(c, to: nil)
                allMins = simd_min(allMins, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
                allMaxs = simd_max(allMaxs, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
            }
        }
        guard allMins.x < Float.greatestFiniteMagnitude else { return }

        let centre = (allMins + allMaxs) * 0.5
        let d      = simd_length(allMaxs - allMins) * 0.5

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        pov.simdPosition = centre + eye * (d * 2.5)
        pov.simdLook(at: centre, up: up, localFront: pov.simdWorldFront)
        defaultCameraController.target = SCNVector3(centre.x, centre.y, centre.z)
        SCNTransaction.commit()
    }
}

// MARK: - SwiftUI wrapper

struct SceneKitView: NSViewRepresentable {

    var scene: SCNScene?
    var shouldResetCamera: Bool

    func makeNSView(context: Context) -> GCodeSCNView {
        let view = GCodeSCNView()
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        view.preferredFramesPerSecond = 60

        view.onResetCamera = { [weak view] in
            guard let view else { return }
            frameCamera(in: view)
        }

        return view
    }

    func updateNSView(_ nsView: GCodeSCNView, context: Context) {
        guard let scene else {
            nsView.scene = nil
            return
        }

        if nsView.scene !== scene {
            attachLights(to: scene)
            nsView.scene = scene
            // Defer framing by one runloop cycle so SceneKit has rendered one frame
            // and bounding boxes are fully computed before we read them.
            DispatchQueue.main.async { frameCamera(in: nsView) }
        }

        if shouldResetCamera {
            DispatchQueue.main.async { frameCamera(in: nsView) }
        }
    }

    // MARK: - Lighting

    private func attachLights(to scene: SCNScene) {
        let ambient       = SCNLight()
        ambient.type      = .ambient
        ambient.intensity = 150
        ambient.color     = NSColor.white
        let ambNode       = SCNNode()
        ambNode.light     = ambient
        scene.rootNode.addChildNode(ambNode)
    }

    private func attachCameraLights(to pov: SCNNode) {
        let key       = SCNLight()
        key.type      = .directional
        key.intensity = 900
        key.color     = NSColor.white
        let keyNode   = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 5, Float.pi / 6, 0)
        pov.addChildNode(keyNode)

        let fill       = SCNLight()
        fill.type      = .directional
        fill.intensity = 350
        fill.color     = NSColor(white: 0.85, alpha: 1)
        let fillNode   = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        pov.addChildNode(fillNode)

        let rim       = SCNLight()
        rim.type      = .directional
        rim.intensity = 200
        rim.color     = NSColor(white: 0.6, alpha: 1)
        let rimNode   = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(Float.pi / 6, Float.pi, 0)
        pov.addChildNode(rimNode)
    }

    // MARK: - Camera framing

    private func frameCamera(in view: GCodeSCNView) {
        guard let scene = view.scene else { return }

        var allMins = SIMD3<Float>( Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude)
        var allMaxs = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                                   -Float.greatestFiniteMagnitude,
                                   -Float.greatestFiniteMagnitude)

        for node in scene.rootNode.childNodes {
            guard node.geometry != nil, node.name != "grid" else { continue }
            let (mn, mx) = node.boundingBox
            let corners: [SCNVector3] = [
                SCNVector3(mn.x, mn.y, mn.z), SCNVector3(mx.x, mn.y, mn.z),
                SCNVector3(mn.x, mx.y, mn.z), SCNVector3(mx.x, mx.y, mn.z),
                SCNVector3(mn.x, mn.y, mx.z), SCNVector3(mx.x, mn.y, mx.z),
                SCNVector3(mn.x, mx.y, mx.z), SCNVector3(mx.x, mx.y, mx.z),
            ]
            for c in corners {
                let w = node.convertPosition(c, to: nil)
                allMins = simd_min(allMins, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
                allMaxs = simd_max(allMaxs, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
            }
        }

        guard allMins.x < Float.greatestFiniteMagnitude else { return }

        let centre   = (allMins + allMaxs) * 0.5
        let span     = allMaxs - allMins
        let radius   = simd_length(span) * 0.5
        let distance = radius * 2.5

        // Slight front-left-above angle for a natural initial view.
        let camPos = centre + SIMD3<Float>(0, -distance * 0.4, distance)

        let pov: SCNNode
        if let existing = view.pointOfView {
            pov = existing
        } else {
            let camNode = SCNNode()
            camNode.camera = SCNCamera()
            attachCameraLights(to: camNode)
            scene.rootNode.addChildNode(camNode)
            view.pointOfView = camNode
            pov = camNode
        }

        pov.camera?.zNear = Double(radius) * 0.001
        pov.camera?.zFar  = Double(radius) * 20

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        pov.simdPosition = camPos
        pov.simdLook(at: centre, up: SIMD3<Float>(0, 0, 1), localFront: pov.simdWorldFront)
        view.defaultCameraController.target = SCNVector3(centre.x, centre.y, centre.z)
        SCNTransaction.commit()
    }
}
