import SceneKit
import AppKit
import simd

/// Renders a mesh to a `CGImage` with an offscreen `SCNRenderer`.
///
/// Used by the thumbnail extension (Finder icons); the preview extension only
/// takes `defaultColor` from here (it shows a live `GCodeSCNView` instead).
/// The image is returned as a `CGImage` so the caller can draw it straight
/// into the context Quick Look hands it — no PNG encode/decode round trip.
nonisolated enum GCodeSnapshotRenderer {

    /// Default object colour for Quick Look (the extensions cannot read the
    /// app's preferences).
    static let defaultColor = NSColor(red: 0.75, green: 0.75, blue: 0.80, alpha: 1)

    /// Render `mesh` into an image of `pixelSize` pixels.
    ///
    /// - Parameters:
    ///   - background: Clear colour; pass `.clear` for a transparent image
    ///     (Finder thumbnails).
    ///   - antialiasing: 4× MSAA for the large preview; thumbnails are
    ///     downsampled by Finder anyway and can use less.
    static func render(mesh: MeshData,
                       color: NSColor = defaultColor,
                       pixelSize: CGSize,
                       background: NSColor,
                       antialiasing: SCNAntialiasingMode = .multisampling4X) -> CGImage? {
        guard !mesh.isEmpty, pixelSize.width >= 1, pixelSize.height >= 1,
              let device = MTLCreateSystemDefaultDevice()
        else { return nil }

        let (scene, cameraNode) = makeScene(mesh: mesh, color: color, background: background,
                                            aspect: Float(pixelSize.width / pixelSize.height))

        // ── Offscreen render ──────────────────────────────────────────────────
        // `snapshot` renders with multisampling, resolves, and reads back in
        // one call (the previous hand-rolled texture path had no antialiasing).
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene       = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        let image = renderer.snapshot(atTime: 0, with: pixelSize, antialiasingMode: antialiasing)
        var rect  = CGRect(origin: .zero, size: pixelSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Scene with the mesh centred at the origin, a camera fitted to it for
    /// the given aspect ratio, and the light rig. Returns the camera node.
    private static func makeScene(mesh: MeshData,
                          color: NSColor = defaultColor,
                          background: NSColor,
                          aspect: Float) -> (SCNScene, SCNNode) {
        // ── Scene ─────────────────────────────────────────────────────────────
        let scene    = SCNScene()
        scene.background.contents = background
        let meshNode = SCNNode(geometry: mesh.makeGeometry(color: color))
        let centre   = (mesh.boundsMin + mesh.boundsMax) * 0.5
        meshNode.simdPosition = -centre          // centre the mesh at the origin
        scene.rootNode.addChildNode(meshNode)

        // ── Camera ────────────────────────────────────────────────────────────
        // Three-quarter view from the front-left, slightly above; +Z is up as
        // on the print bed. The distance is fitted to the bounding box
        // corners rather than the bounding sphere, so the object fills the
        // image instead of floating in a lot of empty space.
        let camera     = SCNCamera()
        camera.fieldOfView = 30
        camera.projectionDirection = .vertical
        let cameraNode = SCNNode()
        cameraNode.camera = camera

        let viewDir  = simd_normalize(SIMD3<Float>(-0.55, -0.75, 0.5))   // centre → camera
        let distance = fittedDistance(halfExtent: (mesh.boundsMax - mesh.boundsMin) * 0.5,
                                      viewDir: viewDir,
                                      fovY: Float(camera.fieldOfView) * .pi / 180,
                                      aspect: aspect) * 1.06          // small margin
        cameraNode.simdPosition = viewDir * distance
        cameraNode.simdLook(at: .zero, up: SIMD3<Float>(0, 0, 1), localFront: SCNNode.simdLocalFront)
        let radius     = simd_length(mesh.boundsMax - mesh.boundsMin) * 0.5
        camera.zNear   = Double(max(distance - radius * 1.1, distance * 0.01))
        camera.zFar    = Double(distance + radius * 1.1)
        scene.rootNode.addChildNode(cameraNode)

        // ── Lights (attached to the camera, same rig as the main app) ─────────
        let ambient = SCNLight()
        ambient.type      = .ambient
        ambient.intensity = 200
        let ambientNode   = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type      = .directional
        key.intensity = 900
        let keyNode   = SCNNode(); keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 5, Float.pi / 6, 0)
        cameraNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type      = .directional
        fill.intensity = 300
        fill.color     = NSColor(white: 0.8, alpha: 1)
        let fillNode   = SCNNode(); fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        cameraNode.addChildNode(fillNode)

        return (scene, cameraNode)
    }

    /// Smallest camera distance at which all eight corners of a box with
    /// `halfExtent`, centred at the origin, lie inside the view frustum when
    /// looking from direction `viewDir` (Z up).
    private static func fittedDistance(halfExtent h: SIMD3<Float>,
                                       viewDir: SIMD3<Float>,
                                       fovY: Float,
                                       aspect: Float) -> Float {
        let right = simd_normalize(simd_cross(-viewDir, SIMD3<Float>(0, 0, 1)))
        let up    = simd_cross(right, -viewDir)
        let tanY  = tan(fovY * 0.5)
        let tanX  = tanY * aspect

        var distance: Float = 0.001
        for sx in [-1, 1] as [Float] {
            for sy in [-1, 1] as [Float] {
                for sz in [-1, 1] as [Float] {
                    let p = h * SIMD3(sx, sy, sz)
                    // Depth from the camera is (distance − p·viewDir); the corner
                    // fits when its lateral offset ≤ tan(fov/2) · depth.
                    let towards = simd_dot(p, viewDir)
                    distance = max(distance,
                                   towards + abs(simd_dot(p, right)) / tanX,
                                   towards + abs(simd_dot(p, up))    / tanY)
                }
            }
        }
        return distance
    }
}
