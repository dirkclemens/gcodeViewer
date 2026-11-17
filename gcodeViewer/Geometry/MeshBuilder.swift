import SceneKit
import AppKit
import simd

// MARK: - Marching Cubes lookup table (Lorensen & Cline, 1987)
//
// Corner numbering (cube minimum corner at origin):
//   7---6        +Z up, +X right, +Y into screen
//   |   |
//   4---5   (top face)
//   3---2
//   |   |
//   0---1   (bottom face)
//
// Edge numbering:
//   0: 0-1   1: 1-2   2: 2-3   3: 3-0   (bottom ring)
//   4: 4-5   5: 5-6   6: 6-7   7: 7-4   (top ring)
//   8: 0-4   9: 1-5  10: 2-6  11: 3-7   (vertical)

// Triangle edge-index lists; groups of 3, terminated by -1.
// Winding produces inward normals in the standard Lorensen convention;
// MCTables swaps the 2nd and 3rd index of every triangle to face outward.
nonisolated private let mcTriTable: [[Int]] = [
    [-1],
    [0,8,3,-1],
    [0,1,9,-1],
    [1,8,3,9,8,1,-1],
    [1,2,10,-1],
    [0,8,3,1,2,10,-1],
    [9,2,10,0,2,9,-1],
    [2,8,3,2,10,8,10,9,8,-1],
    [3,11,2,-1],
    [0,11,2,8,11,0,-1],
    [1,9,0,2,3,11,-1],
    [1,11,2,1,9,11,9,8,11,-1],
    [3,10,1,11,10,3,-1],
    [0,10,1,0,8,10,8,11,10,-1],
    [3,9,0,3,11,9,11,10,9,-1],
    [9,8,10,10,8,11,-1],
    [4,7,8,-1],
    [4,3,0,7,3,4,-1],
    [0,1,9,8,4,7,-1],
    [4,1,9,4,7,1,7,3,1,-1],
    [1,2,10,8,4,7,-1],
    [3,4,7,3,0,4,1,2,10,-1],
    [9,2,10,9,0,2,8,4,7,-1],
    [2,10,9,2,9,7,2,7,3,7,9,4,-1],
    [8,4,7,3,11,2,-1],
    [11,4,7,11,2,4,2,0,4,-1],
    [9,0,1,8,4,7,2,3,11,-1],
    [4,7,11,9,4,11,9,11,2,9,2,1,-1],
    [3,10,1,3,11,10,7,8,4,-1],
    [1,11,10,1,4,11,1,0,4,7,11,4,-1],
    [4,7,8,9,0,11,9,11,10,11,0,3,-1],
    [4,7,11,4,11,9,9,11,10,-1],
    [9,5,4,-1],
    [9,5,4,0,8,3,-1],
    [0,5,4,1,5,0,-1],
    [8,5,4,8,3,5,3,1,5,-1],
    [1,2,10,9,5,4,-1],
    [3,0,8,1,2,10,4,9,5,-1],
    [5,2,10,5,4,2,4,0,2,-1],
    [2,10,5,3,2,5,3,5,4,3,4,8,-1],
    [9,5,4,2,3,11,-1],
    [0,11,2,0,8,11,4,9,5,-1],
    [0,5,4,0,1,5,2,3,11,-1],
    [2,1,5,2,5,8,2,8,11,4,8,5,-1],
    [10,3,11,10,1,3,9,5,4,-1],
    [4,9,5,0,8,1,8,10,1,8,11,10,-1],
    [5,4,0,5,0,11,5,11,10,11,0,3,-1],
    [5,4,8,5,8,10,10,8,11,-1],
    [9,7,8,5,7,9,-1],
    [9,3,0,9,5,3,5,7,3,-1],
    [0,7,8,0,1,7,1,5,7,-1],
    [1,5,3,3,5,7,-1],
    [9,7,8,9,5,7,10,1,2,-1],
    [10,1,2,9,5,0,5,3,0,5,7,3,-1],
    [8,0,2,8,2,5,8,5,7,10,5,2,-1],
    [2,10,5,2,5,3,3,5,7,-1],
    [7,9,5,7,8,9,3,11,2,-1],
    [9,5,7,9,7,2,9,2,0,2,7,11,-1],
    [2,3,11,0,1,8,1,7,8,1,5,7,-1],
    [11,2,1,11,1,7,7,1,5,-1],
    [9,5,8,8,5,7,10,1,3,10,3,11,-1],
    [5,7,0,5,0,9,7,11,0,1,0,10,11,10,0,-1],
    [11,10,0,11,0,3,10,5,0,8,0,7,5,7,0,-1],
    [11,10,5,7,11,5,-1],
    [10,6,5,-1],
    [0,8,3,5,10,6,-1],
    [9,0,1,5,10,6,-1],
    [1,8,3,1,9,8,5,10,6,-1],
    [1,6,5,2,6,1,-1],
    [1,6,5,1,2,6,3,0,8,-1],
    [9,6,5,9,0,6,0,2,6,-1],
    [5,9,8,5,8,2,5,2,6,3,2,8,-1],
    [2,3,11,10,6,5,-1],
    [11,0,8,11,2,0,10,6,5,-1],
    [0,1,9,2,3,11,5,10,6,-1],
    [5,10,6,1,9,2,9,11,2,9,8,11,-1],
    [6,3,11,6,5,3,5,1,3,-1],
    [0,8,11,0,11,5,0,5,1,5,11,6,-1],
    [3,11,6,0,3,6,0,6,5,0,5,9,-1],
    [6,5,9,6,9,11,11,9,8,-1],
    [5,10,6,4,7,8,-1],
    [4,3,0,4,7,3,6,5,10,-1],
    [1,9,0,5,10,6,8,4,7,-1],
    [10,6,5,1,9,7,1,7,3,7,9,4,-1],
    [6,1,2,6,5,1,4,7,8,-1],
    [1,2,5,5,2,6,3,0,4,3,4,7,-1],
    [8,4,7,9,0,5,0,6,5,0,2,6,-1],
    [7,3,9,7,9,4,3,2,9,5,9,6,2,6,9,-1],
    [3,11,2,7,8,4,10,6,5,-1],
    [5,10,6,4,7,2,4,2,0,2,7,11,-1],
    [0,1,9,4,7,8,2,3,11,5,10,6,-1],
    [9,2,1,9,11,2,9,4,11,7,11,4,5,10,6,-1],
    [8,4,7,3,11,5,3,5,1,5,11,6,-1],
    [5,1,11,5,11,6,1,0,11,7,11,4,0,4,11,-1],
    [0,5,9,0,6,5,0,3,6,11,6,3,8,4,7,-1],
    [6,5,9,6,9,11,4,7,9,7,11,9,-1],
    [10,4,9,6,4,10,-1],
    [4,10,6,4,9,10,0,8,3,-1],
    [10,0,1,10,6,0,6,4,0,-1],
    [8,3,1,8,1,6,8,6,4,6,1,10,-1],
    [1,4,9,1,2,4,2,6,4,-1],
    [3,0,8,1,2,9,2,4,9,2,6,4,-1],
    [0,2,4,4,2,6,-1],
    [8,3,2,8,2,4,4,2,6,-1],
    [10,4,9,10,6,4,11,2,3,-1],
    [0,8,2,2,8,11,4,9,10,4,10,6,-1],
    [3,11,2,0,1,6,0,6,4,6,1,10,-1],
    [6,4,1,6,1,10,4,8,1,2,1,11,8,11,1,-1],
    [9,6,4,9,3,6,9,1,3,11,6,3,-1],
    [8,11,1,8,1,0,11,6,1,9,1,4,6,4,1,-1],
    [3,11,6,3,6,0,0,6,4,-1],
    [6,4,8,11,6,8,-1],
    [7,10,6,7,8,10,8,9,10,-1],
    [0,7,3,0,10,7,0,9,10,6,7,10,-1],
    [10,6,7,1,10,7,1,7,8,1,8,0,-1],
    [10,6,7,10,7,1,1,7,3,-1],
    [1,2,6,1,6,8,1,8,9,8,6,7,-1],
    [2,6,9,2,9,1,6,7,9,0,9,3,7,3,9,-1],
    [7,8,0,7,0,6,6,0,2,-1],
    [7,3,2,6,7,2,-1],
    [2,3,11,10,6,8,10,8,9,8,6,7,-1],
    [2,0,7,2,7,11,0,9,7,6,7,10,9,10,7,-1],
    [1,8,0,1,7,8,1,10,7,6,7,10,2,3,11,-1],
    [11,2,1,11,1,7,10,6,1,6,7,1,-1],
    [8,9,6,8,6,7,9,1,6,11,6,3,1,3,6,-1],
    [0,9,1,11,6,7,-1],
    [7,8,0,7,0,6,3,11,0,11,6,0,-1],
    [7,11,6,-1],
    [7,6,11,-1],
    [3,0,8,11,7,6,-1],
    [0,1,9,11,7,6,-1],
    [8,1,9,8,3,1,11,7,6,-1],
    [10,1,2,6,11,7,-1],
    [1,2,10,3,0,8,6,11,7,-1],
    [2,9,0,2,10,9,6,11,7,-1],
    [6,11,7,2,10,3,10,8,3,10,9,8,-1],
    [7,2,3,6,2,7,-1],
    [7,0,8,7,6,0,6,2,0,-1],
    [2,7,6,2,3,7,0,1,9,-1],
    [1,6,2,1,8,6,1,9,8,8,7,6,-1],
    [10,7,6,10,1,7,1,3,7,-1],
    [10,7,6,1,7,10,1,8,7,1,0,8,-1],
    [0,3,7,0,7,10,0,10,9,6,10,7,-1],
    [7,6,10,7,10,8,8,10,9,-1],
    [6,8,4,11,8,6,-1],
    [3,6,11,3,0,6,0,4,6,-1],
    [8,6,11,8,4,6,9,0,1,-1],
    [9,4,6,9,6,3,9,3,1,11,3,6,-1],
    [6,8,4,6,11,8,2,10,1,-1],
    [1,2,10,3,0,11,0,6,11,0,4,6,-1],
    [4,11,8,4,6,11,0,2,9,2,10,9,-1],
    [10,9,3,10,3,2,9,4,3,11,3,6,4,6,3,-1],
    [8,2,3,8,4,2,4,6,2,-1],
    [0,4,2,4,6,2,-1],
    [1,9,0,2,3,4,2,4,6,4,3,8,-1],
    [1,9,4,1,4,2,2,4,6,-1],
    [8,1,3,8,6,1,8,4,6,6,10,1,-1],
    [10,1,0,10,0,6,6,0,4,-1],
    [4,6,3,4,3,8,6,10,3,0,3,9,10,9,3,-1],
    [10,9,4,6,10,4,-1],
    [4,9,5,7,6,11,-1],
    [0,8,3,4,9,5,11,7,6,-1],
    [5,0,1,5,4,0,7,6,11,-1],
    [11,7,6,8,3,4,3,5,4,3,1,5,-1],
    [9,5,4,10,1,2,7,6,11,-1],
    [6,11,7,1,2,10,0,8,3,4,9,5,-1],
    [7,6,11,5,4,10,4,2,10,4,0,2,-1],
    [3,4,8,3,5,4,3,2,5,10,5,2,11,7,6,-1],
    [7,2,3,7,6,2,5,4,9,-1],
    [9,5,4,0,8,6,0,6,2,6,8,7,-1],
    [3,6,2,3,7,6,1,5,0,5,4,0,-1],
    [6,2,8,6,8,7,2,1,8,4,8,5,1,5,8,-1],
    [9,5,4,10,1,6,1,7,6,1,3,7,-1],
    [1,6,10,1,7,6,1,0,7,8,7,0,9,5,4,-1],
    [4,0,10,4,10,5,0,3,10,6,10,7,3,7,10,-1],
    [7,6,10,7,10,8,5,4,10,4,8,10,-1],
    [6,9,5,6,11,9,11,8,9,-1],
    [3,6,11,0,6,3,0,5,6,0,9,5,-1],
    [0,11,8,0,5,11,0,1,5,5,6,11,-1],
    [6,11,3,6,3,5,5,3,1,-1],
    [1,2,10,9,5,11,9,11,8,11,5,6,-1],
    [0,11,3,0,6,11,0,9,6,5,6,9,1,2,10,-1],
    [11,8,5,11,5,6,8,0,5,10,5,2,0,2,5,-1],
    [6,11,3,6,3,5,2,10,3,10,5,3,-1],
    [5,8,9,5,2,8,5,6,2,3,8,2,-1],
    [9,5,6,9,6,0,0,6,2,-1],
    [1,5,8,1,8,0,5,6,8,3,8,2,6,2,8,-1],
    [1,5,6,2,1,6,-1],
    [1,3,6,1,6,10,3,8,6,5,6,9,8,9,6,-1],
    [10,1,0,10,0,6,9,5,0,5,6,0,-1],
    [0,3,8,5,6,10,-1],
    [10,5,6,-1],
    [11,5,10,7,5,11,-1],
    [11,5,10,11,7,5,8,3,0,-1],
    [5,11,7,5,10,11,1,9,0,-1],
    [10,7,5,10,11,7,9,8,1,8,3,1,-1],
    [11,1,2,11,7,1,7,5,1,-1],
    [0,8,3,1,2,7,1,7,5,7,2,11,-1],
    [9,7,5,9,2,7,9,0,2,2,11,7,-1],
    [7,5,2,7,2,11,5,9,2,3,2,8,9,8,2,-1],
    [2,5,10,2,3,5,3,7,5,-1],
    [8,2,0,8,5,2,8,7,5,10,2,5,-1],
    [9,0,1,5,10,3,5,3,7,3,10,2,-1],
    [9,8,2,9,2,1,8,7,2,10,2,5,7,5,2,-1],
    [1,3,5,3,7,5,-1],
    [0,8,7,0,7,1,1,7,5,-1],
    [9,0,3,9,3,5,5,3,7,-1],
    [9,8,7,5,9,7,-1],
    [5,8,4,5,10,8,10,11,8,-1],
    [5,0,4,5,11,0,5,10,11,11,3,0,-1],
    [0,1,9,8,4,10,8,10,11,10,4,5,-1],
    [10,11,4,10,4,5,11,3,4,9,4,1,3,1,4,-1],
    [2,5,1,2,8,5,2,11,8,4,5,8,-1],
    [0,4,11,0,11,3,4,5,11,2,11,1,5,1,11,-1],
    [0,2,5,0,5,9,2,11,5,4,5,8,11,8,5,-1],
    [9,4,5,2,11,3,-1],
    [2,5,10,3,5,2,3,4,5,3,8,4,-1],
    [5,10,2,5,2,4,4,2,0,-1],
    [3,10,2,3,5,10,3,8,5,4,5,8,0,1,9,-1],
    [5,10,2,5,2,4,1,9,2,9,4,2,-1],
    [8,4,5,8,5,3,3,5,1,-1],
    [0,4,5,1,0,5,-1],
    [8,4,5,8,5,3,9,0,5,0,3,5,-1],
    [9,4,5,-1],
    [4,11,7,4,9,11,9,10,11,-1],
    [0,8,3,4,9,7,9,11,7,9,10,11,-1],
    [1,10,11,1,11,4,1,4,0,7,4,11,-1],
    [3,1,4,3,4,8,1,10,4,7,4,11,10,11,4,-1],
    [4,11,7,9,11,4,9,2,11,9,1,2,-1],
    [9,7,4,9,11,7,9,1,11,2,11,1,0,8,3,-1],
    [11,7,4,11,4,2,2,4,0,-1],
    [11,7,4,11,4,2,8,3,4,3,2,4,-1],
    [2,9,10,2,7,9,2,3,7,7,4,9,-1],
    [9,10,7,9,7,4,10,2,7,8,7,0,2,0,7,-1],
    [3,7,10,3,10,2,7,4,10,1,10,0,4,0,10,-1],
    [1,10,2,8,7,4,-1],
    [4,9,1,4,1,7,7,1,3,-1],
    [4,9,1,4,1,7,0,8,1,8,7,1,-1],
    [4,0,3,7,4,3,-1],
    [4,8,7,-1],
    [9,10,8,10,11,8,-1],
    [3,0,9,3,9,11,11,9,10,-1],
    [0,1,10,0,10,8,8,10,11,-1],
    [3,1,10,11,3,10,-1],
    [1,2,11,1,11,9,9,11,8,-1],
    [3,0,9,3,9,11,1,2,9,2,11,9,-1],
    [0,2,11,8,0,11,-1],
    [3,2,11,-1],
    [2,3,8,2,8,10,10,8,9,-1],
    [9,10,2,0,9,2,-1],
    [2,3,8,2,8,10,0,1,8,1,10,8,-1],
    [1,10,2,-1],
    [1,3,8,9,1,8,-1],
    [0,9,1,-1],
    [0,3,8,-1],
    [-1]
]

/// Flattened, cache-friendly form of the triangle table plus per-triangle
/// face normals, built once on first use.
nonisolated private struct MCTables: Sendable {
    /// 256 × 16 edge indices, outward winding, −1 terminated.
    let triangles: [Int8]
    /// Number of triangles per case.
    let triangleCount: [UInt8]
    /// 256 × 5 unnormalised face normals (area-weighted, in voxel units).
    let normals: [SIMD3<Float>]

    static let shared = MCTables()

    private init() {
        let corner: [SIMD3<Float>] = [
            SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0),
            SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)
        ]
        let edgeCorners: [(Int, Int)] = [
            (0,1),(1,2),(2,3),(3,0), (4,5),(5,6),(6,7),(7,4), (0,4),(1,5),(2,6),(3,7)
        ]
        let edgeMid = edgeCorners.map { (corner[$0.0] + corner[$0.1]) * 0.5 }

        var tris    = [Int8](repeating: -1, count: 256 * 16)
        var counts  = [UInt8](repeating: 0, count: 256)
        var normals = [SIMD3<Float>](repeating: .zero, count: 256 * 5)

        for (c, list) in mcTriTable.enumerated() {
            var t = 0
            while t * 3 + 2 < list.count && list[t * 3] >= 0 {
                let e0 = list[t * 3], e1 = list[t * 3 + 2], e2 = list[t * 3 + 1]   // swapped → outward
                tris[c * 16 + t * 3]     = Int8(e0)
                tris[c * 16 + t * 3 + 1] = Int8(e1)
                tris[c * 16 + t * 3 + 2] = Int8(e2)
                normals[c * 5 + t] = simd_cross(edgeMid[e1] - edgeMid[e0], edgeMid[e2] - edgeMid[e0])
                t += 1
            }
            counts[c] = UInt8(t)
        }
        triangles     = tris
        triangleCount = counts
        self.normals  = normals
    }
}

// MARK: - Mesh data

/// A finished triangle mesh in GPU-ready form. Plain bytes, so it can cross
/// actor boundaries; the (non-Sendable) `SCNGeometry` is created by the caller.
nonisolated struct MeshData: Sendable {
    /// Interleaved Float32 `position.xyz, normal.xyz` — 24 bytes per vertex.
    let vertexData: Data
    /// UInt32 triangle indices.
    let indexData: Data
    let vertexCount: Int
    let triangleCount: Int
    /// Axis-aligned bounds of all vertices (both zero for an empty mesh).
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    var isEmpty: Bool { triangleCount == 0 }

    static var empty: MeshData {
        MeshData(vertexData: Data(), indexData: Data(), vertexCount: 0, triangleCount: 0,
                 boundsMin: .zero, boundsMax: .zero)
    }

    /// Wraps the buffers in an `SCNGeometry` without copying or converting them.
    func makeGeometry(color: NSColor) -> SCNGeometry {
        let stride = 6 * MemoryLayout<Float>.size
        let vSrc = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: vertexCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)
        let nSrc = SCNGeometrySource(
            data: vertexData, semantic: .normal, vectorCount: vertexCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 3 * MemoryLayout<Float>.size, dataStride: stride)
        let elem = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: triangleCount, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geo = SCNGeometry(sources: [vSrc, nSrc], elements: [elem])

        let mat = SCNMaterial()
        mat.diffuse.contents  = color
        mat.specular.contents = NSColor.white
        mat.shininess         = 60
        mat.lightingModel     = .phong
        mat.isDoubleSided     = false
        geo.materials = [mat]
        return geo
    }
}

// MARK: - Mesh builder

/// Converts a `VoxelGrid` into a smooth triangle mesh using Marching Cubes.
///
/// Implementation follows the "Flying Edges" idea (Schroeder et al., 2015):
///
///  * Pass 1 counts, per grid row, the surface vertices on its X/Y/Z edges
///    and, per Z slab, the triangles. A prefix sum turns the counts into
///    final buffer offsets.
///  * Pass 2 writes vertices and triangles straight to their final position.
///
/// Because every offset is known up front, there is no hash map for vertex
/// de-duplication (a shared vertex's index is a popcount away), no buffer
/// growth, and all slabs can be processed on all cores at once. Empty and
/// fully solid regions are skipped 64 cubes at a time.
nonisolated enum MeshBuilder {

    // MARK: - Public API

    @concurrent
    static func build(grid: VoxelGrid) async -> MeshData {
        guard !grid.isEmpty, grid.nx > 1, grid.ny > 1, grid.nz > 1 else { return .empty }

        let job = MeshJob(grid: grid)
        let nz  = grid.nz

        // ── Pass 1: count ──────────────────────────────────────────────────
        await parallel(count: nz) { z in job.countSlab(z) }
        guard job.resolveOffsets(), !Task.isCancelled else { return .empty }

        // ── Pass 2: emit ───────────────────────────────────────────────────
        await parallel(count: nz) { z in job.emitVertices(z) }
        // A slab's triangles add their face normals to vertices on the slab's
        // lower and upper plane. Slabs of equal parity share no vertices, so
        // each half can run fully in parallel without synchronisation.
        await parallel(count: nz / 2)       { k in job.emitTriangles(2 * k) }
        await parallel(count: (nz - 1) / 2) { k in job.emitTriangles(2 * k + 1) }

        let (lo, hi) = await job.finishNormals()
        return job.makeMeshData(boundsMin: lo, boundsMax: hi)
    }

    // MARK: - Parallel loop

    /// Runs `body(0 ..< count)` on all cores, in contiguous chunks.
    fileprivate static func parallel(
        count: Int,
        _ body: @escaping @Sendable (Int) -> Void
    ) async {
        guard count > 0 else { return }
        let chunks    = min(count, ProcessInfo.processInfo.activeProcessorCount * 4)
        let chunkSize = (count + chunks - 1) / chunks
        await withTaskGroup(of: Void.self) { group in
            var start = 0
            while start < count {
                let range = start..<min(start + chunkSize, count)
                group.addTask {
                    for i in range { body(i) }
                }
                start = range.upperBound
            }
        }
    }
}

// MARK: - Mesh job

/// Shared state of one mesh build. Every parallel task writes to a disjoint
/// part of the buffers, which is what makes the unchecked Sendable sound.
nonisolated private final class MeshJob: @unchecked Sendable {

    private let grid: VoxelGrid
    private let nx: Int, ny: Int, nz: Int, wpr: Int
    private let tables = MCTables.shared

    /// Three entries per grid row (z · ny + y): the number — after
    /// `resolveOffsets()` the first index — of vertices on the row's
    /// X edges, Y edges (towards y + 1) and Z edges (towards z + 1).
    private let rowBase: UnsafeMutablePointer<Int32>
    /// Per slab: triangle count, after `resolveOffsets()` first triangle index.
    private let triBase: UnsafeMutablePointer<Int>

    private var vertexCount   = 0
    private var triangleCount = 0
    private var vertices: UnsafeMutablePointer<Float>?     // 6 floats per vertex
    private var indices:  UnsafeMutablePointer<UInt32>?    // 3 per triangle
    private var buffersHandedOff = false

    init(grid: VoxelGrid) {
        self.grid = grid
        nx = grid.nx; ny = grid.ny; nz = grid.nz; wpr = grid.wordsPerRow
        rowBase = .allocate(capacity: 3 * ny * nz)
        triBase = .allocate(capacity: nz)
        triBase.initialize(repeating: 0, count: nz)
    }

    deinit {
        rowBase.deallocate()
        triBase.deallocate()
        if !buffersHandedOff {
            free(vertices)
            free(indices)
        }
    }

    // MARK: Row access

    /// Word `w` of `row` shifted down by one cell: bit x holds cell x + 1.
    @inline(__always)
    private func next(_ row: UnsafePointer<UInt64>, _ w: Int) -> UInt64 {
        (row[w] >> 1) | (w + 1 < wpr ? row[w + 1] << 63 : 0)
    }

    /// Marching Cubes case of the cube whose minimum corner is bit `bit`.
    @inline(__always)
    private func caseIndex(
        _ a: UInt64, _ a1: UInt64, _ b: UInt64, _ b1: UInt64,
        _ c: UInt64, _ c1: UInt64, _ d: UInt64, _ d1: UInt64, _ bit: UInt64
    ) -> Int {
        let v = ((a  >> bit) & 1)      | ((a1 >> bit) & 1) << 1
              | ((b1 >> bit) & 1) << 2 | ((b  >> bit) & 1) << 3
              | ((c  >> bit) & 1) << 4 | ((c1 >> bit) & 1) << 5
              | ((d1 >> bit) & 1) << 6 | ((d  >> bit) & 1) << 7
        return Int(v)
    }

    // MARK: Pass 1

    func countSlab(_ z: Int) {
        grid.words.withUnsafeBufferPointer { buf in
            tables.triangleCount.withUnsafeBufferPointer { triCount in
                guard let words = buf.baseAddress else { return }
                let hasZ = z + 1 < nz
                var slabTriangles = 0

                for y in 0..<ny {
                    let row  = z * ny + y
                    let a    = words + row * wpr
                    let hasY = y + 1 < ny
                    let b    = hasY ? a + wpr : a
                    let c    = hasZ ? a + ny * wpr : a
                    let d    = hasY ? c + wpr : c
                    var cx = 0, cy = 0, cz = 0

                    for w in 0..<wpr {
                        let av = a[w], bv = b[w], cv = c[w], dv = d[w]
                        let a1 = next(a, w)
                        cx += (av ^ a1).nonzeroBitCount
                        cy += (av ^ bv).nonzeroBitCount
                        cz += (av ^ cv).nonzeroBitCount

                        guard hasY && hasZ else { continue }
                        let b1 = next(b, w), c1 = next(c, w), d1 = next(d, w)
                        let anySet = av | a1 | bv | b1 | cv | c1 | dv | d1
                        let allSet = av & a1 & bv & b1 & cv & c1 & dv & d1
                        var active = anySet & ~allSet
                        while active != 0 {
                            let bit = UInt64(active.trailingZeroBitCount)
                            active &= active - 1
                            slabTriangles += Int(triCount[caseIndex(av, a1, bv, b1, cv, c1, dv, d1, bit)])
                        }
                    }
                    rowBase[3 * row]     = Int32(cx)
                    rowBase[3 * row + 1] = Int32(cy)
                    rowBase[3 * row + 2] = Int32(cz)
                }
                triBase[z] = slabTriangles
            }
        }
    }

    /// Turns the per-row / per-slab counts into buffer offsets and allocates
    /// the output buffers. Returns false if there is nothing to build.
    func resolveOffsets() -> Bool {
        var v = 0
        for i in 0..<(3 * ny * nz) {
            let n = Int(rowBase[i])
            guard v <= Int(Int32.max) - n else { return false }   // would overflow 32-bit indices
            rowBase[i] = Int32(v)
            v += n
        }
        var t = 0
        for z in 0..<nz {
            let n = triBase[z]
            triBase[z] = t
            t += n
        }
        guard v > 0, t > 0 else { return false }
        vertexCount   = v
        triangleCount = t
        vertices = malloc(v * 6 * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
        indices  = malloc(t * 3 * MemoryLayout<UInt32>.size)?.assumingMemoryBound(to: UInt32.self)
        return vertices != nil && indices != nil
    }

    // MARK: Pass 2 — vertices

    func emitVertices(_ z: Int) {
        guard let out = vertices else { return }
        let vs = grid.voxelSize
        let origin = grid.origin

        grid.words.withUnsafeBufferPointer { buf in
            guard let words = buf.baseAddress else { return }
            let hasZ = z + 1 < nz
            let pz = origin.z + Float(z) * vs

            for y in 0..<ny {
                let row  = z * ny + y
                let a    = words + row * wpr
                let b    = y + 1 < ny ? a + wpr : a
                let c    = hasZ ? a + ny * wpr : a
                let py   = origin.y + Float(y) * vs
                var ix = Int(rowBase[3 * row])
                var iy = Int(rowBase[3 * row + 1])
                var iz = Int(rowBase[3 * row + 2])

                @inline(__always) func put(_ i: Int, _ x: Float, _ y: Float, _ z: Float) {
                    let p = out + i * 6
                    p[0] = x; p[1] = y; p[2] = z
                    p[3] = 0; p[4] = 0; p[5] = 0
                }

                for w in 0..<wpr {
                    let av = a[w]
                    var xm = av ^ next(a, w)
                    var ym = av ^ b[w]
                    var zm = av ^ c[w]
                    guard (xm | ym | zm) != 0 else { continue }
                    let xBase = origin.x + Float(w * 64) * vs
                    while xm != 0 {
                        let bit = xm.trailingZeroBitCount
                        xm &= xm - 1
                        put(ix, xBase + (Float(bit) + 0.5) * vs, py, pz)
                        ix += 1
                    }
                    while ym != 0 {
                        let bit = ym.trailingZeroBitCount
                        ym &= ym - 1
                        put(iy, xBase + Float(bit) * vs, py + 0.5 * vs, pz)
                        iy += 1
                    }
                    while zm != 0 {
                        let bit = zm.trailingZeroBitCount
                        zm &= zm - 1
                        put(iz, xBase + Float(bit) * vs, py, pz + 0.5 * vs)
                        iz += 1
                    }
                }
            }
        }
    }

    // MARK: Pass 2 — triangles + normal accumulation

    func emitTriangles(_ z: Int) {
        guard z + 1 < nz, let verts = vertices, let idx = indices else { return }

        grid.words.withUnsafeBufferPointer { buf in
        tables.triangles.withUnsafeBufferPointer { triTable in
        tables.normals.withUnsafeBufferPointer { normalTable in
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 12) { ev in
            guard let words = buf.baseAddress else { return }
            var t = triBase[z]

            for y in 0..<(ny - 1) {
                let row = z * ny + y
                let up  = row + ny                      // same y, next slab
                let a = words + row * wpr               // (y,   z)
                let b = a + wpr                         // (y+1, z)
                let c = words + up * wpr                // (y,   z+1)
                let d = c + wpr                         // (y+1, z+1)

                // Running index of the first vertex of the current word in
                // each of the eight edge streams this cube row touches.
                var nX00 = UInt32(rowBase[3 * row]),           nX10 = UInt32(rowBase[3 * (row + 1)])
                var nX01 = UInt32(rowBase[3 * up]),            nX11 = UInt32(rowBase[3 * (up + 1)])
                var nY0  = UInt32(rowBase[3 * row + 1]),       nY1  = UInt32(rowBase[3 * up + 1])
                var nZ0  = UInt32(rowBase[3 * row + 2]),       nZ1  = UInt32(rowBase[3 * (row + 1) + 2])

                for w in 0..<wpr {
                    let av = a[w], bv = b[w], cv = c[w], dv = d[w]
                    let a1 = next(a, w), b1 = next(b, w), c1 = next(c, w), d1 = next(d, w)
                    let anySet = av | a1 | bv | b1 | cv | c1 | dv | d1
                    guard anySet != 0 else { continue }          // no edges, no cubes
                    let allSet = av & a1 & bv & b1 & cv & c1 & dv & d1

                    // Edge masks: bit x set ⇔ the edge starting at cell x is cut.
                    let mX00 = av ^ a1, mX10 = bv ^ b1, mX01 = cv ^ c1, mX11 = dv ^ d1
                    let mY0  = av ^ bv, mY1  = cv ^ dv
                    let mZ0  = av ^ cv, mZ1  = bv ^ dv

                    var active = anySet & ~allSet
                    while active != 0 {
                        let bit = UInt64(active.trailingZeroBitCount)
                        active &= active - 1
                        let ci = caseIndex(av, a1, bv, b1, cv, c1, dv, d1, bit)

                        // Vertex index = stream base + number of cut edges below.
                        let lo:  UInt64 = (1 &<< bit) &- 1       // cells < x
                        let lo1: UInt64 = (2 &<< bit) &- 1       // cells < x + 1
                        ev[0]  = nX00 + UInt32((mX00 & lo ).nonzeroBitCount)
                        ev[1]  = nY0  + UInt32((mY0  & lo1).nonzeroBitCount)
                        ev[2]  = nX10 + UInt32((mX10 & lo ).nonzeroBitCount)
                        ev[3]  = nY0  + UInt32((mY0  & lo ).nonzeroBitCount)
                        ev[4]  = nX01 + UInt32((mX01 & lo ).nonzeroBitCount)
                        ev[5]  = nY1  + UInt32((mY1  & lo1).nonzeroBitCount)
                        ev[6]  = nX11 + UInt32((mX11 & lo ).nonzeroBitCount)
                        ev[7]  = nY1  + UInt32((mY1  & lo ).nonzeroBitCount)
                        ev[8]  = nZ0  + UInt32((mZ0  & lo ).nonzeroBitCount)
                        ev[9]  = nZ0  + UInt32((mZ0  & lo1).nonzeroBitCount)
                        ev[10] = nZ1  + UInt32((mZ1  & lo1).nonzeroBitCount)
                        ev[11] = nZ1  + UInt32((mZ1  & lo ).nonzeroBitCount)

                        var k = ci * 16
                        var n = ci * 5
                        while triTable[k] >= 0 {
                            let i0 = ev[Int(triTable[k])]
                            let i1 = ev[Int(triTable[k + 1])]
                            let i2 = ev[Int(triTable[k + 2])]
                            let o = idx + t * 3
                            o[0] = i0; o[1] = i1; o[2] = i2

                            let fn = normalTable[n]
                            let p0 = verts + Int(i0) * 6 + 3
                            let p1 = verts + Int(i1) * 6 + 3
                            let p2 = verts + Int(i2) * 6 + 3
                            p0[0] += fn.x; p0[1] += fn.y; p0[2] += fn.z
                            p1[0] += fn.x; p1[1] += fn.y; p1[2] += fn.z
                            p2[0] += fn.x; p2[1] += fn.y; p2[2] += fn.z

                            t += 1; k += 3; n += 1
                        }
                    }

                    nX00 += UInt32(mX00.nonzeroBitCount); nX10 += UInt32(mX10.nonzeroBitCount)
                    nX01 += UInt32(mX01.nonzeroBitCount); nX11 += UInt32(mX11.nonzeroBitCount)
                    nY0  += UInt32(mY0.nonzeroBitCount);  nY1  += UInt32(mY1.nonzeroBitCount)
                    nZ0  += UInt32(mZ0.nonzeroBitCount);  nZ1  += UInt32(mZ1.nonzeroBitCount)
                }
            }
        }}}}
    }

    // MARK: Normals + bounds

    /// Normalises the accumulated vertex normals and returns the mesh bounds.
    func finishNormals() async -> (SIMD3<Float>, SIMD3<Float>) {
        guard let verts = vertices else { return (.zero, .zero) }
        let count     = vertexCount
        let chunks    = max(1, min(count / 16_384, ProcessInfo.processInfo.activeProcessorCount * 2))
        let chunkSize = (count + chunks - 1) / chunks
        let base      = SendablePointer(verts)

        return await withTaskGroup(of: (SIMD3<Float>, SIMD3<Float>).self) { group in
            var start = 0
            while start < count {
                let range = start..<min(start + chunkSize, count)
                group.addTask {
                    var lo = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
                    var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                    for i in range {
                        let p = base.pointer + i * 6
                        let pos = SIMD3<Float>(p[0], p[1], p[2])
                        lo = simd_min(lo, pos)
                        hi = simd_max(hi, pos)
                        let n   = SIMD3<Float>(p[3], p[4], p[5])
                        let len = simd_length(n)
                        let u   = len > 0 ? n / len : SIMD3<Float>(0, 0, 1)
                        p[3] = u.x; p[4] = u.y; p[5] = u.z
                    }
                    return (lo, hi)
                }
                start = range.upperBound
            }
            var lo = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for await (l, h) in group {
                lo = simd_min(lo, l)
                hi = simd_max(hi, h)
            }
            return (lo, hi)
        }
    }

    /// Hands the buffers over to `Data` (no copy).
    func makeMeshData(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) -> MeshData {
        guard let verts = vertices, let idx = indices, !buffersHandedOff else { return .empty }
        buffersHandedOff = true
        return MeshData(
            vertexData: Data(bytesNoCopy: verts,
                             count: vertexCount * 6 * MemoryLayout<Float>.size,
                             deallocator: .free),
            indexData: Data(bytesNoCopy: idx,
                            count: triangleCount * 3 * MemoryLayout<UInt32>.size,
                            deallocator: .free),
            vertexCount: vertexCount,
            triangleCount: triangleCount,
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )
    }
}

nonisolated private struct SendablePointer<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
    init(_ pointer: UnsafeMutablePointer<T>) { self.pointer = pointer }
}
