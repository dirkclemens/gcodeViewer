import SwiftUI
import SceneKit
import AppKit

// MARK: - Custom SCNView with full keyboard + modifier-drag controls

/// SCNView subclass that adds industry-standard modifier-key camera controls
/// on top of SceneKit's built-in orbit/zoom/pan.
///
/// Control map
/// ───────────────────────────────────────────────────────────────────────────
/// Plain drag          → Orbit (turntable)          [SceneKit built-in]
/// Shift + drag        → Pan (translate)
/// Alt/Option + drag   → Orbit (Maya convention alias)
/// Ctrl + drag         → Dolly zoom
/// Scroll wheel        → Zoom                        [SceneKit built-in]
/// Shift + scroll      → Pan vertically
/// Ctrl  + scroll      → Pan horizontally
/// F                   → Frame object (reset camera)
/// Numpad 1 / KP1      → Front view  (+Y axis)
/// Numpad 3 / KP3      → Right view  (+X axis)
/// Numpad 7 / KP7      → Top view    (+Z axis)
/// + / =               → Zoom in
/// - / _               → Zoom out
/// ───────────────────────────────────────────────────────────────────────────
final class GCodeSCNView: SCNView {

    /// Called when the user presses F or a numpad view key.
    var onResetCamera: (() -> Void)?

    // Tracks the mouse position from the previous drag event.
    private var lastDragLocation: NSPoint = .zero

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        // Let SceneKit handle plain left-drag (orbit).
        // Modifier drags are intercepted in mouseDragged.
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let loc  = event.locationInWindow
        let dx   = Float(loc.x - lastDragLocation.x)
        let dy   = Float(loc.y - lastDragLocation.y)
        lastDragLocation = loc

        let mods = event.modifierFlags.intersection([.shift, .option, .control, .command])

        switch mods {

        case .shift:
            // Pan: translate the camera and its target in screen space.
            pan(dx: dx, dy: dy)

        case .option:
            // Option/Alt + drag → orbit (Maya muscle-memory convention).
            // We forward this to SceneKit's controller as if it were a plain drag.
            defaultCameraController.beginInteraction(loc, withViewport: bounds.size)
            defaultCameraController.continueInteraction(loc, withViewport: bounds.size, sensitivity: 1)

        case .control:
            // Ctrl + drag → dolly (zoom by moving camera along its axis).
            dolly(delta: dy - dx)

        default:
            // No recognised modifier — let SceneKit handle it (plain orbit).
            super.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        defaultCameraController.endInteraction(event.locationInWindow,
                                               withViewport: bounds.size,
                                               velocity: .zero)
        super.mouseUp(with: event)
    }

    // MARK: - Scroll wheel

    override func scrollWheel(with event: NSEvent) {
        let dx = Float(event.scrollingDeltaX)
        let dy = Float(event.scrollingDeltaY)
        let mods = event.modifierFlags.intersection([.shift, .control])

        switch mods {
        case .shift:
            // Shift + scroll → pan vertically (and a little horizontally).
            pan(dx: dx * 0.5, dy: dy * 0.5)
        case .control:
            // Ctrl + scroll → pan horizontally.
            pan(dx: dy * 0.5, dy: 0)
        default:
            // Plain scroll → zoom (SceneKit handles this natively).
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {

        case "f", "F":
            onResetCamera?()

        case "+", "=":
            dolly(delta: -20)

        case "-", "_":
            dolly(delta: 20)

        case "1":
            // Front view: camera on +Y axis looking toward origin
            setStandardView(eye: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1))

        case "3":
            // Right/side view: camera on +X axis
            setStandardView(eye: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1))

        case "7":
            // Top view: camera on +Z axis looking down
            setStandardView(eye: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0))

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Camera manipulation helpers

    /// Pan (translate) the camera and its orbit target in screen space.
    private func pan(dx: Float, dy: Float) {
        guard let pov = pointOfView else { return }

        // Scale factor: larger distance from target → faster pan so it feels linear.
        let target   = defaultCameraController.target
        let camPos   = SIMD3<Float>(pov.simdPosition)
        let tgt      = SIMD3<Float>(target)
        let distance = simd_length(camPos - tgt)
        let speed    = distance * 0.001

        // Camera right and up vectors in world space.
        let right = SIMD3<Float>(pov.simdTransform.columns.0.x,
                                 pov.simdTransform.columns.0.y,
                                 pov.simdTransform.columns.0.z)
        let up    = SIMD3<Float>(pov.simdTransform.columns.1.x,
                                 pov.simdTransform.columns.1.y,
                                 pov.simdTransform.columns.1.z)

        let delta = (-right * dx + up * dy) * speed * 40

        pov.simdPosition += delta
        defaultCameraController.target = SCNVector3(tgt + delta)
    }

    /// Dolly: move the camera along its look-at axis (zoom by distance).
    private func dolly(delta: Float) {
        guard let pov = pointOfView else { return }

        let target   = defaultCameraController.target
        let camPos   = SIMD3<Float>(pov.simdPosition)
        let tgt      = SIMD3<Float>(target)
        let toTarget = tgt - camPos
        let distance = simd_length(toTarget)

        // Prevent overshooting through the target.
        let step = distance * 0.01 * delta
        guard abs(step) < distance * 0.9 else { return }

        let direction = simd_normalize(toTarget)
        pov.simdPosition += direction * step
    }

    /// Position the camera along a cardinal axis at a distance that frames the scene.
    private func setStandardView(eye: SIMD3<Float>, up: SIMD3<Float>) {
        guard let scene, let pov = pointOfView else { return }

        // Compute world-space bounding box (respects node pivot).
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
        let dist   = d * 2.5

        let newPos = centre + eye * dist

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        pov.simdPosition = newPos
        pov.simdLook(at: centre, up: up, localFront: pov.simdWorldFront)
        defaultCameraController.target = SCNVector3(centre)
        SCNTransaction.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI wrapper around GCodeSCNView.
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

    // MARK: - Helpers

    private func attachLights(to scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 180
        ambient.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.color = NSColor.white
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 5, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 300
        fill.color = NSColor(white: 0.8, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        scene.rootNode.addChildNode(fillNode)
    }

    private func frameCamera(in view: GCodeSCNView) {
        guard let scene = view.scene else { return }

        // Compute the world-space bounding box by walking geometry nodes.
        var allMins = SIMD3<Float>( Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude,
                                    Float.greatestFiniteMagnitude)
        var allMaxs = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                                   -Float.greatestFiniteMagnitude,
                                   -Float.greatestFiniteMagnitude)

        for node in scene.rootNode.childNodes {
            guard node.geometry != nil, node.name != "grid" else { continue }
            // convertPosition maps local-space corners to world space,
            // correctly accounting for the node's position and pivot.
            let (mn, mx) = node.boundingBox
            let corners: [SCNVector3] = [
                SCNVector3(mn.x, mn.y, mn.z), SCNVector3(mx.x, mn.y, mn.z),
                SCNVector3(mn.x, mx.y, mn.z), SCNVector3(mx.x, mx.y, mn.z),
                SCNVector3(mn.x, mn.y, mx.z), SCNVector3(mx.x, mn.y, mx.z),
                SCNVector3(mn.x, mx.y, mx.z), SCNVector3(mx.x, mx.y, mx.z),
            ]
            for c in corners {
                let w = node.convertPosition(c, to: nil) // nil = world space
                allMins = simd_min(allMins, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
                allMaxs = simd_max(allMaxs, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
            }
        }

        guard allMins.x < Float.greatestFiniteMagnitude else { return }

        let centre = (allMins + allMaxs) * 0.5
        let span   = allMaxs - allMins
        let radius = simd_length(span) * 0.5
        let distance = radius * 2.5

        // Camera sits at a slight angle (front-left-above) for a natural first view.
        let camOffset = SIMD3<Float>(0, -distance * 0.4, distance)
        let camPos    = centre + camOffset

        // Update or create the camera node.
        let pov: SCNNode
        if let existing = view.pointOfView {
            pov = existing
        } else {
            let camNode = SCNNode()
            camNode.camera = SCNCamera()
            scene.rootNode.addChildNode(camNode)
            view.pointOfView = camNode
            pov = camNode
        }

        // Always update zNear/zFar so tiny or huge models clip correctly.
        pov.camera?.zNear = Double(radius) * 0.001
        pov.camera?.zFar  = Double(radius) * 20

        // Position + orient the camera, then sync the orbit controller target.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        pov.simdPosition = camPos
        pov.simdLook(at: centre, up: SIMD3<Float>(0, 0, 1), localFront: pov.simdWorldFront)
        view.defaultCameraController.target = SCNVector3(centre.x, centre.y, centre.z)
        SCNTransaction.commit()
    }
}
