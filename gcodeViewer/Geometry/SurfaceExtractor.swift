import Foundation
import simd

typealias VoxelCoord = SIMD3<Int32>

/// Converts extruding G-code moves into a filled voxel set.
///
/// Pipeline:
///  1. Voxelise all extruding segments with the Amanatides-Woo 3-D DDA.
///  2. Dilate the filled set by one voxel in all six axis directions to
///     close gaps between adjacent extrusion passes and across layer boundaries.
///
/// The returned set is the *complete* filled volume; surface extraction is
/// handled downstream by the Marching Cubes algorithm in MeshBuilder.
enum SurfaceExtractor {

    // MARK: - Public API

    nonisolated static func extract(
        moves: [Move],
        voxelSize: Float,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async -> Set<VoxelCoord> {

        return await Task.detached(priority: .userInitiated) {

            // ── Phase 1: fill voxels along extrusion paths ─────────────────
            var filled = Set<VoxelCoord>()
            filled.reserveCapacity(500_000)

            let extruding = moves.filter { $0.isExtrusion }
            let total     = extruding.count
            guard total > 0 else { return Set<VoxelCoord>() }

            for (i, move) in extruding.enumerated() {
                let voxels = voxeliseLine(from: move.from, to: move.position, voxelSize: voxelSize)
                for v in voxels { filled.insert(v) }

                if i % 5_000 == 0 {
                    await progressHandler(Double(i) / Double(total) * 0.7)
                }
            }

            // ── Phase 2: 6-neighbour dilation ──────────────────────────────
            // Closes gaps between adjacent extrusion lines and across layers.
            let offsets: [VoxelCoord] = [
                SIMD3( 1,  0,  0), SIMD3(-1,  0,  0),
                SIMD3( 0,  1,  0), SIMD3( 0, -1,  0),
                SIMD3( 0,  0,  1), SIMD3( 0,  0, -1),
            ]
            var dilated = filled
            dilated.reserveCapacity(filled.count * 2)
            for v in filled {
                for off in offsets { dilated.insert(v &+ off) }
            }

            await progressHandler(1.0)
            return dilated

        }.value
    }

    // MARK: - Amanatides-Woo 3-D DDA

    /// Returns every voxel the segment [a, b] passes through.
    nonisolated private static func voxeliseLine(
        from a: SIMD3<Float>,
        to   b: SIMD3<Float>,
        voxelSize: Float
    ) -> [VoxelCoord] {

        var current = toVoxel(a, size: voxelSize)
        let end     = toVoxel(b, size: voxelSize)

        if current == end { return [current] }

        let diff = b - a
        let len  = simd_length(diff)
        guard len > 0 else { return [current] }
        let dir  = diff / len

        // Step direction per axis
        let stepX = dir.x > 0 ? Int32(1) : (dir.x < 0 ? Int32(-1) : Int32(0))
        let stepY = dir.y > 0 ? Int32(1) : (dir.y < 0 ? Int32(-1) : Int32(0))
        let stepZ = dir.z > 0 ? Int32(1) : (dir.z < 0 ? Int32(-1) : Int32(0))

        // Distance along ray to first voxel boundary in each axis
        let ox = Float(current.x) * voxelSize
        let oy = Float(current.y) * voxelSize
        let oz = Float(current.z) * voxelSize

        var tMaxX: Float = stepX > 0 ? (ox + voxelSize - a.x) / dir.x
                         : stepX < 0 ? (ox - a.x) / dir.x
                         : .infinity
        var tMaxY: Float = stepY > 0 ? (oy + voxelSize - a.y) / dir.y
                         : stepY < 0 ? (oy - a.y) / dir.y
                         : .infinity
        var tMaxZ: Float = stepZ > 0 ? (oz + voxelSize - a.z) / dir.z
                         : stepZ < 0 ? (oz - a.z) / dir.z
                         : .infinity

        // Parametric step size to cross one full voxel in each axis
        let tDeltaX: Float = stepX != 0 ? abs(voxelSize / dir.x) : .infinity
        let tDeltaY: Float = stepY != 0 ? abs(voxelSize / dir.y) : .infinity
        let tDeltaZ: Float = stepZ != 0 ? abs(voxelSize / dir.z) : .infinity

        var result: [VoxelCoord] = [current]

        while true {
            if tMaxX < tMaxY {
                if tMaxX < tMaxZ {
                    current.x += stepX
                    tMaxX     += tDeltaX
                } else {
                    current.z += stepZ
                    tMaxZ     += tDeltaZ
                }
            } else {
                if tMaxY < tMaxZ {
                    current.y += stepY
                    tMaxY     += tDeltaY
                } else {
                    current.z += stepZ
                    tMaxZ     += tDeltaZ
                }
            }
            result.append(current)
            if current == end { break }
            // Safety: stop if we overshot (floating-point can cause this)
            if min(tMaxX, min(tMaxY, tMaxZ)) > len + voxelSize { break }
        }

        return result
    }

    nonisolated private static func toVoxel(_ pos: SIMD3<Float>, size: Float) -> VoxelCoord {
        SIMD3<Int32>(
            Int32(floor(pos.x / size)),
            Int32(floor(pos.y / size)),
            Int32(floor(pos.z / size))
        )
    }
}
