import SceneKit
import simd

/// Builds a flat grid node placed at Z = 0 (the print bed plane).
///#imageLiteral(resourceName: "Bildschirmfoto 2026-04-03 um 13.30.04.png")
/// The grid is added to the same SCNScene as the mesh, so it
/// automatically moves, rotates, and pans with the camera alongside
/// the printed object.
///
/// Layout
/// ──────
/// • Minor lines every 10 mm  — dim colour
/// • Major lines every 50 mm  — brighter colour
/// • The grid extends `margin` mm beyond the object's XY footprint
///   on all four sides.
enum GridBuilder {

    nonisolated static func build(minX: Float, maxX: Float,
                                  minY: Float, maxY: Float) -> SCNNode {
        let minorStep: Float = 10
        let majorStep: Float = 50
        let margin:    Float = 20

        // Expand to the nearest multiple of minorStep, then add margin.
        let x0 = (floor((minX - margin) / minorStep) * minorStep)
        let x1 = (ceil ((maxX + margin) / minorStep) * minorStep)
        let y0 = (floor((minY - margin) / minorStep) * minorStep)
        let y1 = (ceil ((maxY + margin) / minorStep) * minorStep)

        var vertices:  [SCNVector3] = []
        var minorIdx:  [Int32]      = []
        var majorIdx:  [Int32]      = []

        let isMajor: (Float) -> Bool = { v in
            abs(v.truncatingRemainder(dividingBy: majorStep)) < 0.5
        }

        // Lines parallel to Y axis (varying X)
        var x = x0
        while x <= x1 + 0.001 {
            let i = Int32(vertices.count)
            vertices.append(SCNVector3(x, y0, 0))
            vertices.append(SCNVector3(x, y1, 0))
            if isMajor(x) {
                majorIdx.append(contentsOf: [i, i + 1])
            } else {
                minorIdx.append(contentsOf: [i, i + 1])
            }
            x += minorStep
        }

        // Lines parallel to X axis (varying Y)
        var y = y0
        while y <= y1 + 0.001 {
            let i = Int32(vertices.count)
            vertices.append(SCNVector3(x0, y, 0))
            vertices.append(SCNVector3(x1, y, 0))
            if isMajor(y) {
                majorIdx.append(contentsOf: [i, i + 1])
            } else {
                minorIdx.append(contentsOf: [i, i + 1])
            }
            y += minorStep
        }

        // Geometry sources
        let vertexSource = SCNGeometrySource(vertices: vertices)

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial]       = []

        if !minorIdx.isEmpty {
            elements.append(SCNGeometryElement(
                indices: minorIdx,
                primitiveType: .line
            ))
            materials.append(lineMaterial(red: 0.35, green: 0.35, blue: 0.38, alpha: 0.6))
        }

        if !majorIdx.isEmpty {
            elements.append(SCNGeometryElement(
                indices: majorIdx,
                primitiveType: .line
            ))
            materials.append(lineMaterial(red: 0.55, green: 0.55, blue: 0.60, alpha: 0.85))
        }

        let geometry          = SCNGeometry(sources: [vertexSource], elements: elements)
        geometry.materials    = materials

        let node              = SCNNode(geometry: geometry)
        node.name             = "grid"
        return node
    }

    // MARK: - Helpers

    private nonisolated static func lineMaterial(red: CGFloat, green: CGFloat,
                                     blue: CGFloat, alpha: CGFloat) -> SCNMaterial {
        let mat                  = SCNMaterial()
        mat.diffuse.contents     = NSColor(red: red, green: green, blue: blue, alpha: alpha)
        mat.lightingModel        = .constant   // unaffected by scene lights
        mat.isDoubleSided        = true
        mat.writesToDepthBuffer  = true
        mat.readsFromDepthBuffer = true
        return mat
    }
}
