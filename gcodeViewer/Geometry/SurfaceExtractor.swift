import Foundation
import simd

/// Dense, bit-packed occupancy grid.
///
/// One bit per voxel, 64 voxels per word along X. Rows are padded to whole
/// words; padding bits are always zero. The outermost shell of cells is
/// guaranteed to be empty, so a surface extracted from the grid is closed.
nonisolated struct VoxelGrid: Sendable {
    let nx: Int
    let ny: Int
    let nz: Int
    let wordsPerRow: Int
    /// Edge length of a voxel in millimetres. May be larger than the size
    /// requested if the model would not fit the memory budget otherwise.
    let voxelSize: Float
    /// World-space position of the centre of cell (0, 0, 0).
    let origin: SIMD3<Float>
    /// `words[(z * ny + y) * wordsPerRow + (x >> 6)]`, bit `x & 63`.
    let words: [UInt64]

    var isEmpty: Bool { words.isEmpty }

    static var empty: VoxelGrid {
        VoxelGrid(nx: 0, ny: 0, nz: 0, wordsPerRow: 0, voxelSize: 1, origin: .zero, words: [])
    }
}

/// Converts extruding G-code moves into a solid voxel volume.
///
/// Pipeline:
///  1. Rasterise every extruding segment with the Amanatides-Woo 3-D DDA.
///  2. Thicken the one-voxel-thin paths to the real bead size (line width in
///     XY, layer height downwards in Z), then apply one 6-neighbour dilation.
///     This closes the gaps between neighbouring lines and layers at *any*
///     voxel size, not only when a voxel is larger than a bead.
///  3. Fill every cavity that cannot be reached from outside (sparse infill).
///     Those surfaces can never be seen, but would otherwise make up most of
///     the triangles.
///
/// All volume passes are word-parallel bit operations (64 voxels per step).
nonisolated enum SurfaceExtractor {

    // MARK: - Public API

    @concurrent
    static func extract(
        model: ParsedGCode,
        voxelSize requestedSize: Float,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async -> VoxelGrid {

        let moves = model.moves

        // ── Bounds of all deposited material ───────────────────────────────
        var lo = SIMD3<Float>(repeating:  .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var extrusionCount = 0
        for m in moves where m.isExtrusion {
            lo = simd_min(lo, simd_min(m.from, m.position))
            hi = simd_max(hi, simd_max(m.from, m.position))
            extrusionCount += 1
        }
        guard extrusionCount > 0,
              simd_reduce_max(simd_abs(lo)) < 1e6, simd_reduce_max(simd_abs(hi)) < 1e6
        else { return .empty }

        // ── Grid layout; coarsen if the volume exceeds the memory budget ───
        let maxCells = 1_000_000_000          // 125 MB per bit plane
        var layout = Layout(lo: lo, hi: hi, voxelSize: max(requestedSize, 0.02), model: model)
        while layout.cellCount > maxCells {
            let factor = Float(pow(Double(layout.cellCount) / Double(maxCells), 1.0 / 3.0))
            layout = Layout(lo: lo, hi: hi,
                            voxelSize: layout.voxelSize * max(factor, 1.02), model: model)
        }
        let total = layout.ny * layout.nz * layout.wpr

        // ── Phase 1: rasterise extrusion paths ─────────────────────────────
        var a = [UInt64](repeating: 0, count: total)
        var index = 0
        while index < moves.count {
            let end = min(index + 65_536, moves.count)
            a.withUnsafeMutableBufferPointer { grid in
                moves.withUnsafeBufferPointer { mv in
                    guard let g = grid.baseAddress else { return }
                    for i in index..<end where mv[i].isExtrusion {
                        rasterise(from: mv[i].from, to: mv[i].position, into: g, layout: layout)
                    }
                }
            }
            index = end
            if Task.isCancelled { return .empty }
            await progressHandler(0.5 * Double(index) / Double(moves.count))
        }

        // ── Phase 2: thicken to bead size + 6-neighbour dilation ───────────
        var b = [UInt64](repeating: 0, count: total)
        var kernels: [Kernel] = []
        for step in 0..<layout.xySteps { kernels.append(step % 2 == 0 ? .square : .cross) }
        if layout.zDown > 0 { kernels.append(.down(layout.zDown)) }
        kernels.append(.cross3D)

        for (k, kernel) in kernels.enumerated() {
            a.withUnsafeBufferPointer { src in
                b.withUnsafeMutableBufferPointer { dst in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                    dilate(kernel, from: s, into: d, layout: layout)
                }
            }
            swap(&a, &b)
            if Task.isCancelled { return .empty }
            await progressHandler(0.5 + 0.3 * Double(k + 1) / Double(kernels.count))
        }

        // ── Phase 3: fill unreachable cavities ─────────────────────────────
        a.withUnsafeMutableBufferPointer { solid in
            b.withUnsafeMutableBufferPointer { scratch in
                guard let s = solid.baseAddress, let e = scratch.baseAddress else { return }
                fillCavities(solid: s, exterior: e, layout: layout)
            }
        }
        await progressHandler(1.0)

        return VoxelGrid(nx: layout.nx, ny: layout.ny, nz: layout.nz,
                         wordsPerRow: layout.wpr,
                         voxelSize: layout.voxelSize,
                         origin: layout.origin,
                         words: a)
    }

    // MARK: - Grid layout

    private struct Layout {
        let voxelSize: Float
        let inv: Float                 // 1 / voxelSize
        let nx: Int, ny: Int, nz: Int
        let wpr: Int                   // words per row
        let x0: Float, y0: Float, z0: Float   // cell index of grid cell 0 (as Float)
        let xySteps: Int               // in-plane thickening passes before the final dilation
        let zDown: Int                 // extra cells filled below each path

        /// A bead's *top* is at the nozzle Z, so a path at an exact multiple of
        /// the voxel size belongs to the cell below it. The bias also keeps
        /// float rounding from scattering equal-Z layers over two cells.
        static let zBias: Float = 0.01

        init(lo: SIMD3<Float>, hi: SIMD3<Float>, voxelSize: Float, model: ParsedGCode) {
            self.voxelSize = voxelSize
            inv = 1 / voxelSize

            // Neighbouring lines are one line width apart, i.e. up to
            // ceil(w / v) cells. The final cross dilation already covers a
            // width of 3 cells; each extra pass adds 2.
            let cellsPerLine  = (model.lineWidth * inv).rounded(.up)
            xySteps = max(0, Int(((cellsPerLine - 3) / 2).rounded(.up)))
            // Layers are up to ceil(h / v) cells apart; fill the bead downwards.
            zDown = max(0, Int((model.layerHeight * inv - Layout.zBias).rounded(.up)) - 1)

            // Margins: room for every dilation plus one guaranteed-empty cell.
            let mxy = xySteps + 2
            let mzLo = zDown + 2
            let mzHi = 2

            let fx0 = (lo.x * inv).rounded(.down), fx1 = (hi.x * inv).rounded(.down)
            let fy0 = (lo.y * inv).rounded(.down), fy1 = (hi.y * inv).rounded(.down)
            let fz0 = (lo.z * inv - Layout.zBias).rounded(.down)
            let fz1 = (hi.z * inv - Layout.zBias).rounded(.down)

            x0 = fx0 - Float(mxy)
            y0 = fy0 - Float(mxy)
            z0 = fz0 - Float(mzLo)
            nx = Int(fx1 - fx0) + 1 + 2 * mxy
            ny = Int(fy1 - fy0) + 1 + 2 * mxy
            nz = Int(fz1 - fz0) + 1 + mzLo + mzHi
            wpr = (nx + 63) / 64
        }

        var cellCount: Int { nx * ny * nz }

        /// World position of the centre of cell (0, 0, 0).
        var origin: SIMD3<Float> {
            SIMD3<Float>(x0 + 0.5, y0 + 0.5, z0 + 0.5) * voxelSize
        }

        /// Continuous grid coordinates of a world position.
        @inline(__always)
        func gridCoord(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(p.x * inv - x0, p.y * inv - y0, p.z * inv - Layout.zBias - z0)
        }
    }

    // MARK: - Amanatides-Woo 3-D DDA

    /// Sets every cell the segment [a, b] passes through.
    @inline(__always)
    private static func rasterise(
        from a: SIMD3<Float>, to b: SIMD3<Float>,
        into grid: UnsafeMutablePointer<UInt64>, layout: Layout
    ) {
        let ga = layout.gridCoord(a)
        let gb = layout.gridCoord(b)
        let fa = ga.rounded(.down)
        let fb = gb.rounded(.down)

        var cx = Int(fa.x), cy = Int(fa.y), cz = Int(fa.z)
        let nx = layout.nx, ny = layout.ny, nz = layout.nz, wpr = layout.wpr

        @inline(__always) func mark(_ x: Int, _ y: Int, _ z: Int) {
            // Unsigned compare also rejects negatives.
            guard UInt(bitPattern: x) < UInt(bitPattern: nx),
                  UInt(bitPattern: y) < UInt(bitPattern: ny),
                  UInt(bitPattern: z) < UInt(bitPattern: nz) else { return }
            grid[(z * ny + y) * wpr + (x >> 6)] |= 1 << UInt64(x & 63)
        }

        mark(cx, cy, cz)

        // Number of cell boundaries to cross per axis. Stepping exactly this
        // often lands on the end cell without any floating-point overshoot.
        var remX = abs(Int(fb.x) - cx), remY = abs(Int(fb.y) - cy), remZ = abs(Int(fb.z) - cz)
        var remaining = remX + remY + remZ
        guard remaining > 0 else { return }

        let d = gb - ga
        let stepX = d.x > 0 ? 1 : -1, stepY = d.y > 0 ? 1 : -1, stepZ = d.z > 0 ? 1 : -1

        // Parametric distance (0…1 along the segment) to the next boundary.
        var tMaxX: Float = remX > 0 ? ((d.x > 0 ? fa.x + 1 : fa.x) - ga.x) / d.x : .infinity
        var tMaxY: Float = remY > 0 ? ((d.y > 0 ? fa.y + 1 : fa.y) - ga.y) / d.y : .infinity
        var tMaxZ: Float = remZ > 0 ? ((d.z > 0 ? fa.z + 1 : fa.z) - ga.z) / d.z : .infinity
        let tDeltaX: Float = remX > 0 ? abs(1 / d.x) : .infinity
        let tDeltaY: Float = remY > 0 ? abs(1 / d.y) : .infinity
        let tDeltaZ: Float = remZ > 0 ? abs(1 / d.z) : .infinity

        while remaining > 0 {
            if tMaxX <= tMaxY && tMaxX <= tMaxZ {
                cx += stepX
                remX -= 1
                tMaxX = remX > 0 ? tMaxX + tDeltaX : .infinity
            } else if tMaxY <= tMaxZ {
                cy += stepY
                remY -= 1
                tMaxY = remY > 0 ? tMaxY + tDeltaY : .infinity
            } else {
                cz += stepZ
                remZ -= 1
                tMaxZ = remZ > 0 ? tMaxZ + tDeltaZ : .infinity
            }
            remaining -= 1
            mark(cx, cy, cz)
        }
    }

    // MARK: - Morphological dilation

    private enum Kernel {
        case cross          // 4-neighbourhood in XY
        case square         // 8-neighbourhood in XY (alternating with .cross → octagon)
        case down(Int)      // extend n cells towards −Z
        case cross3D        // 6-neighbourhood
    }

    /// The word at index `w` of `row`, OR-ed with its two X neighbours.
    @inline(__always)
    private static func spreadX(_ row: UnsafePointer<UInt64>, _ w: Int, _ wpr: Int) -> UInt64 {
        let v = row[w]
        let fromLower: UInt64 = w > 0       ? row[w - 1] >> 63 : 0
        let fromUpper: UInt64 = w + 1 < wpr ? row[w + 1] << 63 : 0
        return v | (v << 1) | (v >> 1) | fromLower | fromUpper
    }

    private static func dilate(
        _ kernel: Kernel,
        from src: UnsafePointer<UInt64>,
        into dst: UnsafeMutablePointer<UInt64>,
        layout: Layout
    ) {
        let ny = layout.ny, nz = layout.nz, wpr = layout.wpr
        let slice = ny * wpr
        let zeroRow = [UInt64](repeating: 0, count: wpr)

        zeroRow.withUnsafeBufferPointer { zeroBuf in
            guard let zero = zeroBuf.baseAddress else { return }
            for z in 0..<nz {
                for y in 0..<ny {
                    let c  = src + (z * ny + y) * wpr
                    let o  = dst + (z * ny + y) * wpr
                    let ym = y > 0      ? c - wpr : zero
                    let yp = y + 1 < ny ? c + wpr : zero

                    switch kernel {
                    case .cross:
                        for w in 0..<wpr {
                            o[w] = spreadX(c, w, wpr) | ym[w] | yp[w]
                        }
                    case .square:
                        for w in 0..<wpr {
                            o[w] = spreadX(c, w, wpr) | spreadX(ym, w, wpr) | spreadX(yp, w, wpr)
                        }
                    case .cross3D:
                        let zm = z > 0      ? c - slice : zero
                        let zp = z + 1 < nz ? c + slice : zero
                        for w in 0..<wpr {
                            o[w] = spreadX(c, w, wpr) | ym[w] | yp[w] | zm[w] | zp[w]
                        }
                    case .down(let count):
                        for w in 0..<wpr { o[w] = c[w] }
                        let reach = min(count, nz - 1 - z)
                        if reach > 0 {
                            for k in 1...reach {
                                let above = c + k * slice
                                for w in 0..<wpr { o[w] |= above[w] }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cavity filling

    /// Mirrors the 64 bits of a word (compiles to a single `rbit` on arm64).
    @inline(__always)
    private static func reverseBits(_ v: UInt64) -> UInt64 {
        var x = v
        x = ((x >> 1) & 0x5555_5555_5555_5555) | ((x & 0x5555_5555_5555_5555) << 1)
        x = ((x >> 2) & 0x3333_3333_3333_3333) | ((x & 0x3333_3333_3333_3333) << 2)
        x = ((x >> 4) & 0x0F0F_0F0F_0F0F_0F0F) | ((x & 0x0F0F_0F0F_0F0F_0F0F) << 4)
        return x.byteSwapped
    }

    /// Flood-fills the empty space reachable from outside the model and turns
    /// everything else solid.
    ///
    /// The flood runs as alternating forward/backward sweeps over the rows.
    /// Within a row, a seed spreads along a whole run of empty cells in O(1)
    /// per word using the carry chain of an addition.
    private static func fillCavities(
        solid: UnsafeMutablePointer<UInt64>,
        exterior ext: UnsafeMutablePointer<UInt64>,
        layout: Layout
    ) {
        let nx = layout.nx, ny = layout.ny, nz = layout.nz, wpr = layout.wpr
        let slice = ny * wpr
        let total = slice * nz
        let lastMask: UInt64 = nx & 63 == 0 ? ~0 : (1 << UInt64(nx & 63)) - 1
        let zeroRow = [UInt64](repeating: 0, count: wpr)

        @inline(__always) func free(_ s: UnsafePointer<UInt64>, _ w: Int) -> UInt64 {
            w == wpr - 1 ? ~s[w] & lastMask : ~s[w]
        }

        // Seed: the bottom slice is an empty margin, hence entirely exterior.
        ext.update(repeating: 0, count: total)
        for r in 0..<ny {
            for w in 0..<wpr { ext[r * wpr + w] = free(solid + r * wpr, w) }
        }

        zeroRow.withUnsafeBufferPointer { zeroBuf in
            guard let zero = zeroBuf.baseAddress else { return }

            /// Pulls exterior cells from the four neighbouring rows into row
            /// (y, z) and spreads them along X. Returns true if the row grew.
            func sweepRow(_ y: Int, _ z: Int) -> Bool {
                let e = ext   + (z * ny + y) * wpr
                let s = UnsafePointer(solid + (z * ny + y) * wpr)
                let ym = y > 0      ? UnsafePointer(e - wpr)   : zero
                let yp = y + 1 < ny ? UnsafePointer(e + wpr)   : zero
                let zm = z > 0      ? UnsafePointer(e - slice) : zero
                let zp = z + 1 < nz ? UnsafePointer(e + slice) : zero

                var grew = false
                for w in 0..<wpr {
                    let seed = (e[w] | ym[w] | yp[w] | zm[w] | zp[w]) & free(s, w)
                    if seed != e[w] { e[w] = seed; grew = true }
                }
                guard grew else { return false }

                // Spread towards +X: adding the seeds to the run mask ripples a
                // carry through each seeded run of free cells.
                var carry: UInt64 = 0
                for w in 0..<wpr {
                    let m = free(s, w), seed = e[w]
                    let (s1, o1) = m.addingReportingOverflow(seed)
                    let (s2, o2) = s1.addingReportingOverflow(carry)
                    e[w]  = ((s2 ^ m) | seed) & m
                    carry = (o1 || o2) ? 1 : 0
                }
                // Spread towards −X: same trick on the bit-reversed row.
                carry = 0
                var w = wpr - 1
                while w >= 0 {
                    let m = reverseBits(free(s, w)), seed = reverseBits(e[w])
                    let (s1, o1) = m.addingReportingOverflow(seed)
                    let (s2, o2) = s1.addingReportingOverflow(carry)
                    e[w]  = reverseBits(((s2 ^ m) | seed) & m)
                    carry = (o1 || o2) ? 1 : 0
                    w -= 1
                }
                return true
            }

            var changed = true
            while changed {
                changed = false
                for z in 0..<nz {
                    for y in 0..<ny where sweepRow(y, z) { changed = true }
                }
                var z = nz - 1
                while z >= 0 {
                    var y = ny - 1
                    while y >= 0 {
                        if sweepRow(y, z) { changed = true }
                        y -= 1
                    }
                    z -= 1
                }
            }
        }

        // Solid = everything the flood did not reach.
        for r in 0..<(ny * nz) {
            let s = solid + r * wpr, e = ext + r * wpr
            for w in 0..<wpr {
                s[w] = w == wpr - 1 ? ~e[w] & lastMask : ~e[w]
            }
        }
    }
}
