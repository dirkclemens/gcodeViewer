import AppKit
import SceneKit
import simd

/// Assembles the viewer scene from a finished mesh: the object centred at the
/// origin, the reference grid under it and an ambient light. The camera and
/// its directional lights are added by `GCodeSCNView.frameContent()`.
///
/// Shared by the app and the interactive Quick Look preview.
enum SceneBuilder {

    /// Name of the reference-grid node; framing and recolouring skip it.
    static let gridNodeName = "grid"

    static func makeScene(mesh: MeshData, color: NSColor) -> SCNScene {
        let scene = SCNScene()
        let node  = SCNNode(geometry: mesh.makeGeometry(color: color))

        let minB = mesh.boundsMin, maxB = mesh.boundsMax
        let centre = (minB + maxB) * 0.5

        // The bounds are already known from the mesh build; handing them to
        // SceneKit saves it a pass over all vertices on the main thread, and
        // makes them valid immediately (no render frame needed).
        node.boundingBox = (SCNVector3(minB.x, minB.y, minB.z), SCNVector3(maxB.x, maxB.y, maxB.z))
        // Centre the model at the origin for nicer default camera framing.
        node.simdPosition = -centre
        scene.rootNode.addChildNode(node)

        // Grid at the bottom face of the object, shifted by the same offset
        // so it still aligns with the object footprint.
        let gridNode = GridBuilder.build(
            minX: minB.x - centre.x, maxX: maxB.x - centre.x,
            minY: minB.y - centre.y, maxY: maxB.y - centre.y
        )
        gridNode.simdPosition = SIMD3<Float>(0, 0, minB.z - centre.z)
        scene.rootNode.addChildNode(gridNode)

        let ambient       = SCNLight()
        ambient.type      = .ambient
        ambient.intensity = 150
        ambient.color     = NSColor.white
        let ambientNode   = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        return scene
    }
}
