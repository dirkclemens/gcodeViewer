import SceneKit
import AppKit
import simd

/// Converts a set of surface voxel coordinates into a renderable SCNGeometry.
///
/// For each voxel in the surface set, only the faces that border an empty voxel
/// are emitted, producing a watertight outer shell mesh.
enum MeshBuilder {

    // MARK: - Face descriptor

    /// One of the six cardinal faces of a unit cube.
    private struct Face: Sendable {
        /// Outward-pointing unit normal.
        let normal: SIMD3<Float>
        /// Four corners of the face in local voxel space (unit cube, origin at 0).
        /// Ordered counter-clockwise when viewed from outside.
        let corners: [SIMD3<Float>]
        /// Neighbour offset in voxel space — the voxel adjacent through this face.
        let neighbour: VoxelCoord
    }

    nonisolated private static let faces: [Face] = [
        // +X
        Face(normal: SIMD3( 1,  0,  0),
             corners: [SIMD3(1,0,0), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(1,1,0)],
             neighbour: SIMD3( 1,  0,  0)),
        // -X
        Face(normal: SIMD3(-1,  0,  0),
             corners: [SIMD3(0,0,0), SIMD3(0,1,0), SIMD3(0,1,1), SIMD3(0,0,1)],
             neighbour: SIMD3(-1,  0,  0)),
        // +Y
        Face(normal: SIMD3( 0,  1,  0),
             corners: [SIMD3(0,1,0), SIMD3(1,1,0), SIMD3(1,1,1), SIMD3(0,1,1)],
             neighbour: SIMD3( 0,  1,  0)),
        // -Y
        Face(normal: SIMD3( 0, -1,  0),
             corners: [SIMD3(0,0,0), SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,0,0)],
             neighbour: SIMD3( 0, -1,  0)),
        // +Z
        Face(normal: SIMD3( 0,  0,  1),
             corners: [SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)],
             neighbour: SIMD3( 0,  0,  1)),
        // -Z
        Face(normal: SIMD3( 0,  0, -1),
             corners: [SIMD3(0,0,0), SIMD3(0,1,0), SIMD3(1,1,0), SIMD3(1,0,0)],
             neighbour: SIMD3( 0,  0, -1)),
    ]

    // MARK: - Public API

    /// Build an SCNGeometry from the surface voxel set.
    /// - Parameters:
    ///   - surfaceVoxels: Set of voxel coordinates on the object's outer shell.
    ///   - voxelSize: Edge length of each voxel in millimetres.
    ///   - color: Material diffuse colour.
    nonisolated static func build(
        surfaceVoxels: Set<VoxelCoord>,
        voxelSize: Float,
        color: NSColor
    ) async -> SCNGeometry {

        return await Task.detached(priority: .userInitiated) {

            var positions: [SCNVector3] = []
            var normals:   [SCNVector3] = []
            var indices:   [Int32]      = []

            positions.reserveCapacity(surfaceVoxels.count * 8)
            normals.reserveCapacity(surfaceVoxels.count * 8)
            indices.reserveCapacity(surfaceVoxels.count * 36)

            for voxel in surfaceVoxels {
                // World-space origin of this voxel
                let ox = Float(voxel.x) * voxelSize
                let oy = Float(voxel.y) * voxelSize
                let oz = Float(voxel.z) * voxelSize

                for face in MeshBuilder.faces {
                    // Only emit this face if the neighbouring voxel is empty
                    let nb = voxel &+ face.neighbour
                    guard !surfaceVoxels.contains(nb) else { continue }

                    let base = Int32(positions.count)

                    for corner in face.corners {
                        positions.append(SCNVector3(
                            ox + corner.x * voxelSize,
                            oy + corner.y * voxelSize,
                            oz + corner.z * voxelSize
                        ))
                        normals.append(SCNVector3(
                            face.normal.x,
                            face.normal.y,
                            face.normal.z
                        ))
                    }

                    // Two triangles (CCW winding): 0-1-2 and 0-2-3
                    indices.append(contentsOf: [
                        base + 0, base + 1, base + 2,
                        base + 0, base + 2, base + 3,
                    ])
                }
            }

            // Build SCNGeometry sources
            let vertexSource = SCNGeometrySource(vertices: positions)
            let normalSource = SCNGeometrySource(normals: normals)
            let element = SCNGeometryElement(
                indices: indices,
                primitiveType: .triangles
            )

            let geometry = SCNGeometry(
                sources: [vertexSource, normalSource],
                elements: [element]
            )

            // Material
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.specular.contents = NSColor.white
            material.shininess = 60
            material.lightingModel = .phong
            material.isDoubleSided = false
            geometry.materials = [material]

            return geometry

        }.value
    }
}
