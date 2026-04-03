import Foundation
import simd

/// Integer voxel coordinate in 3D space.
typealias VoxelCoord = SIMD3<Int32>

/// Converts a list of extruding G-code moves into a set of surface voxels.
///
/// Algorithm:
///  1. Voxelise all extruding line segments (fill a sparse 3D occupancy set).
///  2. Iterate the filled set and retain only voxels that have at least one
///     empty face-neighbour — these form the outer shell.
///
/// This naturally hides all internal infill, walls, and support structures
/// that are completely enclosed by surrounding voxels.
enum SurfaceExtractor {

    // MARK: - Public API

    nonisolated static func extract(
        moves: [Move],
        voxelSize: Float,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async -> Set<VoxelCoord> {

        return await Task.detached(priority: .userInitiated) {

            // ── Phase 1: Fill voxels ────────────────────────────────────────
            var filled = Set<VoxelCoord>()
            filled.reserveCapacity(500_000)

            // Only process moves that actually extrude material.
            // Each Move carries its own start (from) and end (position), so
            // there is no need to chain consecutive moves — gaps caused by
            // travel moves (G0, no extrusion) are naturally ignored.
            let extrudingMoves = moves.filter { $0.isExtrusion }
            let total = extrudingMoves.count
            guard total > 0 else { return Set<VoxelCoord>() }

            for (i, move) in extrudingMoves.enumerated() {
                let voxels = voxeliseLine(from: move.from, to: move.position, voxelSize: voxelSize)
                for v in voxels { filled.insert(v) }

                if i % 5000 == 0 {
                    let p = Double(i) / Double(total)
                    await progressHandler(p * 0.8)
                }
            }

            // ── Phase 2: Extract surface shell ─────────────────────────────
            let neighbours: [VoxelCoord] = [
                SIMD3( 1,  0,  0), SIMD3(-1,  0,  0),
                SIMD3( 0,  1,  0), SIMD3( 0, -1,  0),
                SIMD3( 0,  0,  1), SIMD3( 0,  0, -1),
            ]

            var surface = Set<VoxelCoord>()
            surface.reserveCapacity(filled.count / 2)

            for voxel in filled {
                for n in neighbours {
                    if !filled.contains(voxel &+ n) {
                        surface.insert(voxel)
                        break
                    }
                }
            }

            await progressHandler(1.0)
            return surface

        }.value
    }

    // MARK: - Private helpers

    /// Voxelise the straight line segment between two 3D points using a 3D DDA.
    /// Returns every voxel coordinate the segment passes through.
    nonisolated private static func voxeliseLine(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        voxelSize: Float
    ) -> [VoxelCoord] {

        let diff = b - a
        let length = simd_length(diff)
        guard length > 0 else { return [toVoxel(a, size: voxelSize)] }

        let step = diff / length
        let halfVoxel = voxelSize * 0.5
        var result: [VoxelCoord] = []
        var t: Float = 0
        var current = toVoxel(a, size: voxelSize)
        result.append(current)

        while t < length {
            t += halfVoxel
            let pos = a + step * min(t, length)
            let next = toVoxel(pos, size: voxelSize)
            if next != current {
                result.append(next)
                current = next
            }
        }

        return result
    }

    /// Convert a world-space position (mm) to an integer voxel coordinate.
    nonisolated private static func toVoxel(_ pos: SIMD3<Float>, size: Float) -> VoxelCoord {
        SIMD3<Int32>(
            Int32(floor(pos.x / size)),
            Int32(floor(pos.y / size)),
            Int32(floor(pos.z / size))
        )
    }
}
