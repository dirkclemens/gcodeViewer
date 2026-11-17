import Foundation
import simd

/// Streaming G-code parser.
///
/// Works directly on the bytes of the memory-mapped file — no per-line
/// `String` allocation, no Unicode processing — which makes it roughly two
/// orders of magnitude faster than a `String`-based line splitter.
///
/// Supported commands: G0/G1/G2/G3/G28/G90/G91/G92/M82/M83.
/// Handles LF, CRLF and CR line endings, `;` and `( )` comments, `N` line
/// numbers, `*` checksums, lower-case words and words without separating
/// spaces (`G1X10Y5`).
nonisolated enum GCodeParser {

    // MARK: - Public API

    @concurrent
    static func parse(
        url: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> ParsedGCode {

        let data  = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = data.count

        var state = ParserState()
        state.moves.reserveCapacity(max(1024, count / 28))

        // Parse in ~1 MB slices so progress can be reported and cancellation
        // honoured between slices without any per-line overhead.
        let sliceSize = 1 << 20
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            offset = data.withUnsafeBytes { raw in
                state.consume(raw, from: offset, minimumBytes: sliceSize)
            }
            await progressHandler(Double(offset) / Double(count))
        }
        return state.finish()
    }
}

// MARK: - ASCII constants

nonisolated private enum Ascii {
    static let tab: UInt8 = 9, lf: UInt8 = 10, cr: UInt8 = 13, space: UInt8 = 32
    static let parenOpen: UInt8 = 40, parenClose: UInt8 = 41
    static let star: UInt8 = 42, plus: UInt8 = 43, minus: UInt8 = 45, dot: UInt8 = 46
    static let zero: UInt8 = 48, semicolon: UInt8 = 59
    static let E: UInt8 = 69, G: UInt8 = 71, I: UInt8 = 73, J: UInt8 = 74
    static let M: UInt8 = 77, N: UInt8 = 78, R: UInt8 = 82
    static let X: UInt8 = 88, Y: UInt8 = 89, Z: UInt8 = 90
}

/// 10^0 … 10^18 for decimal scaling.
nonisolated private let powersOfTen: [Double] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9,
    1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18
]

// MARK: - Parser state machine

nonisolated private struct ParserState {

    var moves: [Move] = []

    // Machine state
    private var pos         = SIMD3<Float>(0, 0, 0)   // physical nozzle position
    private var offset      = SIMD3<Float>(0, 0, 0)   // G92 X/Y/Z coordinate offset
    private var lastE: Double = 0                     // logical E as the firmware sees it
    private var relativeMoves     = false
    private var relativeExtrusion = false

    // Layer tracking (only extrusion at a higher Z starts a new layer → Z-hop safe)
    private var layerIndex  = -1
    private var layerCount  = 0
    private var firstLayerZ: Float = 0
    private var lastPrintZ: Float  = -.infinity
    private var sawLayerMarker = false

    // Bead statistics
    private var extrudedPath: Double     = 0   // mm of nozzle travel while extruding
    private var extrudedFilament: Double = 0   // mm of filament pushed during that travel

    // Per-line scratch: parameter values and presence masks (bit = letter − 'A')
    private var seen: UInt32   = 0
    private var valued: UInt32 = 0
    private var vX: Float = 0, vY: Float = 0, vZ: Float = 0
    private var vI: Float = 0, vJ: Float = 0, vR: Float = 0
    private var vE: Double = 0

    // MARK: Slice driver

    /// Parses whole lines starting at `start` until at least `minimumBytes`
    /// have been consumed. Returns the offset of the next unparsed line.
    mutating func consume(_ raw: UnsafeRawBufferPointer, from start: Int, minimumBytes: Int) -> Int {
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return raw.count }
        let n    = raw.count
        let stop = min(n, start + minimumBytes)
        return powersOfTen.withUnsafeBufferPointer { pow10 in
            var i = start
            while i < stop {
                i = parseLine(base, i, n, pow10)
            }
            return i
        }
    }

    // MARK: Line parser

    @inline(__always)
    private func bit(_ letter: UInt8) -> UInt32 { 1 << UInt32(letter - 65) }

    /// Advances past the end of the current line.
    @inline(__always)
    private func skipLine(_ p: UnsafePointer<UInt8>, _ from: Int, _ n: Int) -> Int {
        var i = from
        while i < n {
            let c = p[i]
            i += 1
            if c == Ascii.lf || c == Ascii.cr { break }
        }
        return i
    }

    private mutating func parseLine(
        _ p: UnsafePointer<UInt8>, _ start: Int, _ n: Int,
        _ pow10: UnsafeBufferPointer<Double>
    ) -> Int {
        var i = start
        var cmdLetter: UInt8 = 0
        var cmdCode = 0            // command number × 10 (G92.1 → 921)
        seen = 0
        valued = 0

        scan: while i < n {
            let c = p[i]
            switch c {
            case Ascii.lf, Ascii.cr:
                i += 1
                break scan

            case Ascii.semicolon:
                if !sawLayerMarker && isLayerMarker(p, i + 1, n) {
                    beginPrintBody()
                }
                i = skipLine(p, i, n)
                break scan

            case Ascii.star:                       // checksum — nothing useful follows
                i = skipLine(p, i, n)
                break scan

            case Ascii.parenOpen:                  // inline ( comment )
                i += 1
                while i < n && p[i] != Ascii.parenClose && p[i] != Ascii.lf && p[i] != Ascii.cr { i += 1 }
                if i < n && p[i] == Ascii.parenClose { i += 1 }

            default:
                let u = c & 0xDF                   // ASCII upper-case
                guard u >= 65 && u <= 90 else { i += 1; continue scan }
                i += 1

                // ── Number following the letter ─────────────────────────────
                var j = i
                while j < n && (p[j] == Ascii.space || p[j] == Ascii.tab) { j += 1 }
                var negative = false
                if j < n && (p[j] == Ascii.minus || p[j] == Ascii.plus) {
                    negative = p[j] == Ascii.minus
                    j += 1
                }
                var mantissa: UInt64 = 0
                var digits = 0, fraction = 0, anyDigit = false
                while j < n {
                    let d = p[j] &- Ascii.zero
                    guard d < 10 else { break }
                    if digits < 18 { mantissa = mantissa &* 10 &+ UInt64(d); digits += 1 }
                    anyDigit = true
                    j += 1
                }
                if j < n && p[j] == Ascii.dot {
                    j += 1
                    while j < n {
                        let d = p[j] &- Ascii.zero
                        guard d < 10 else { break }
                        if digits < 18 { mantissa = mantissa &* 10 &+ UInt64(d); digits += 1; fraction += 1 }
                        anyDigit = true
                        j += 1
                    }
                }
                var value = 0.0
                if anyDigit {
                    value = Double(mantissa) / pow10[fraction]
                    if negative { value = -value }
                    i = j
                }

                // ── First word decides what the line is ─────────────────────
                if cmdLetter == 0 {
                    if u == Ascii.N && anyDigit { continue scan }      // line number
                    guard (u == Ascii.G || u == Ascii.M) && anyDigit else {
                        // Not a G/M command (e.g. Klipper macro, T0, garbage).
                        return skipLine(p, i, n)
                    }
                    cmdLetter = u
                    cmdCode   = Int((value * 10).rounded())
                    let interesting: Bool
                    if u == Ascii.G {
                        switch cmdCode {
                        case 0, 10, 20, 30, 280, 900, 910, 920: interesting = true
                        default:                                interesting = false
                        }
                    } else {
                        interesting = cmdCode == 820 || cmdCode == 830
                    }
                    if !interesting { return skipLine(p, i, n) }
                    continue scan
                }

                // ── Parameter word ──────────────────────────────────────────
                let b = bit(u)
                seen |= b
                guard anyDigit else { continue scan }
                switch u {
                case Ascii.X: vX = Float(value)
                case Ascii.Y: vY = Float(value)
                case Ascii.Z: vZ = Float(value)
                case Ascii.E: vE = value
                case Ascii.I: vI = Float(value)
                case Ascii.J: vJ = Float(value)
                case Ascii.R: vR = Float(value)
                default:      continue scan
                }
                valued |= b
            }
        }

        if cmdLetter == Ascii.G {
            switch cmdCode {
            case 0, 10:  linearMove()
            case 20, 30: arcMove(clockwise: cmdCode == 20)
            case 280:    home()
            case 900:    relativeMoves = false
            case 910:    relativeMoves = true
            case 920:    setPosition()
            default:     break
            }
        } else if cmdLetter == Ascii.M {
            if cmdCode == 820 { relativeExtrusion = false }
            if cmdCode == 830 { relativeExtrusion = true }
        }
        return i
    }

    // MARK: Slicer layer marker

    /// True if the comment starting at `start` (just after the `;`) is a
    /// slicer "layer begins" marker: Cura/ideaMaker `;LAYER:n`,
    /// PrusaSlicer/SuperSlicer `;LAYER_CHANGE`, Orca/Bambu `; CHANGE_LAYER`.
    private func isLayerMarker(_ p: UnsafePointer<UInt8>, _ start: Int, _ n: Int) -> Bool {
        var i = start
        while i < n && (p[i] == Ascii.space || p[i] == Ascii.tab) { i += 1 }

        func hasPrefix(_ s: StaticString) -> Bool {
            let len = s.utf8CodeUnitCount
            guard i + len <= n else { return false }
            let q = s.utf8Start
            for k in 0..<len where (p[i + k] & 0xDF) != (q[k] & 0xDF) && p[i + k] != q[k] {
                return false
            }
            return true
        }

        if hasPrefix("LAYER_CHANGE") || hasPrefix("CHANGE_LAYER") { return true }
        if hasPrefix("LAYER:") {
            let k = i + 6
            guard k < n else { return false }
            return p[k] == Ascii.minus || (p[k] &- Ascii.zero) < 10
        }
        return false
    }

    /// Everything before the first slicer layer marker is start G-code
    /// (purge / prime lines far away from the model). Drop it so it neither
    /// shows up in the scene nor inflates the bounding box.
    private mutating func beginPrintBody() {
        sawLayerMarker = true
        moves.removeAll(keepingCapacity: true)
        layerIndex  = -1
        layerCount  = 0
        firstLayerZ = 0
        lastPrintZ  = -.infinity
        extrudedPath     = 0
        extrudedFilament = 0
    }

    // MARK: Command handlers

    @inline(__always)
    private func has(_ letter: UInt8) -> Bool { valued & bit(letter) != 0 }

    /// Target position of a G0–G3 move from the X/Y/Z words on this line.
    @inline(__always)
    private func target() -> SIMD3<Float> {
        var t = pos
        if relativeMoves {
            if has(Ascii.X) { t.x += vX }
            if has(Ascii.Y) { t.y += vY }
            if has(Ascii.Z) { t.z += vZ }
        } else {
            if has(Ascii.X) { t.x = vX + offset.x }
            if has(Ascii.Y) { t.y = vY + offset.y }
            if has(Ascii.Z) { t.z = vZ + offset.z }
        }
        return t
    }

    /// Consumes the E word; returns the amount of filament pushed (≤ 0 → none).
    @inline(__always)
    private mutating func filamentDelta() -> Double {
        guard has(Ascii.E) else { return 0 }
        if relativeExtrusion {
            lastE += vE
            return vE
        }
        let d = vE - lastE
        lastE = vE
        return d
    }

    /// Book-keeping for a move that deposits material.
    @inline(__always)
    private mutating func noteExtrusion(filament: Double, pathLength: Float, z: Float) {
        if z > lastPrintZ {
            if layerCount == 0 { firstLayerZ = z }
            layerCount += 1
            layerIndex += 1
            lastPrintZ  = z
        }
        extrudedPath     += Double(pathLength)
        extrudedFilament += filament
    }

    private mutating func linearMove() {
        let end = target()
        let dE  = filamentDelta()
        guard end != pos else { return }           // pure retract / prime / feedrate line

        let extruding = dE > 0
        if extruding {
            noteExtrusion(filament: dE, pathLength: simd_distance(pos, end), z: end.z)
        }
        moves.append(Move(from: pos, position: end,
                          isExtrusion: extruding, layerIndex: max(layerIndex, 0)))
        pos = end
    }

    private mutating func arcMove(clockwise: Bool) {
        let start = pos
        let end   = target()
        let dE    = filamentDelta()
        let extruding = dE > 0

        // ── Arc centre: I/J form, or R form (Marlin semantics) ──────────────
        var cx: Float, cy: Float
        if has(Ascii.I) || has(Ascii.J) {
            cx = start.x + (has(Ascii.I) ? vI : 0)
            cy = start.y + (has(Ascii.J) ? vJ : 0)
        } else if has(Ascii.R) {
            let dx = end.x - start.x, dy = end.y - start.y
            let d  = hypot(dx, dy)
            guard d > 0 else { return }
            let e: Float = (clockwise != (vR < 0)) ? -1 : 1
            let half = d * 0.5
            let h2   = (vR - half) * (vR + half)
            let h    = h2 > 0 ? h2.squareRoot() : 0
            cx = (start.x + end.x) * 0.5 + e * h * (-dy / d)
            cy = (start.y + end.y) * 0.5 + e * h * ( dx / d)
        } else {
            cx = .nan; cy = .nan
        }

        let radius = hypot(start.x - cx, start.y - cy)
        guard radius.isFinite, radius > 0 else {
            // Malformed arc — fall back to a straight segment.
            if end != start {
                if extruding {
                    noteExtrusion(filament: dE, pathLength: simd_distance(start, end), z: end.z)
                }
                moves.append(Move(from: start, position: end,
                                  isExtrusion: extruding, layerIndex: max(layerIndex, 0)))
                pos = end
            }
            return
        }

        let startAngle = atan2(start.y - cy, start.x - cx)
        var endAngle   = atan2(end.y   - cy, end.x   - cx)
        // Identical start and end angle means a full circle.
        if clockwise {
            if endAngle >= startAngle { endAngle -= 2 * .pi }
        } else {
            if endAngle <= startAngle { endAngle += 2 * .pi }
        }
        let span      = abs(endAngle - startAngle)
        let arcLength = radius * span

        if extruding {
            noteExtrusion(filament: dE, pathLength: hypot(arcLength, end.z - start.z), z: end.z)
        }

        // ≤ 0.5 mm chords and ≤ 15° per chord; bounded for malformed input.
        let byLength = (arcLength / 0.5).rounded(.up)
        let byAngle  = (span / (.pi / 12)).rounded(.up)
        let segments = Int(min(4096, max(1, byLength, byAngle)))
        let sweep    = clockwise ? -span : span
        let layer    = max(layerIndex, 0)

        var prev = start
        for s in 1...segments {
            let next: SIMD3<Float>
            if s == segments {
                next = end                          // land exactly on the commanded end point
            } else {
                let t     = Float(s) / Float(segments)
                let angle = startAngle + sweep * t
                next = SIMD3<Float>(cx + radius * cos(angle),
                                    cy + radius * sin(angle),
                                    start.z + (end.z - start.z) * t)
            }
            if next != prev {
                moves.append(Move(from: prev, position: next,
                                  isExtrusion: extruding, layerIndex: layer))
            }
            prev = next
        }
        pos = end
    }

    /// G28 — home the listed axes, or all axes if none is listed.
    private mutating func home() {
        let x = seen & bit(Ascii.X) != 0
        let y = seen & bit(Ascii.Y) != 0
        let z = seen & bit(Ascii.Z) != 0
        let all = !(x || y || z)
        if all || x { pos.x = 0; offset.x = 0 }
        if all || y { pos.y = 0; offset.y = 0 }
        if all || z { pos.z = 0; offset.z = 0 }
    }

    /// G92 — redefine the logical coordinates of the current position.
    /// The nozzle does not move.
    private mutating func setPosition() {
        if has(Ascii.E) { lastE = vE }
        if has(Ascii.X) { offset.x = pos.x - vX }
        if has(Ascii.Y) { offset.y = pos.y - vY }
        if has(Ascii.Z) { offset.z = pos.z - vZ }
    }

    // MARK: Result

    func finish() -> ParsedGCode {
        // Mean bead cross-section from extruded volume (1.75 mm filament assumed).
        let filamentArea = Double.pi * 0.875 * 0.875
        let beadArea = extrudedPath > 0 ? Float(extrudedFilament * filamentArea / extrudedPath) : 0

        var height: Float = 0.2
        if layerCount > 1 {
            height = (lastPrintZ - firstLayerZ) / Float(layerCount - 1)
        } else if layerCount == 1 {
            height = firstLayerZ
        }
        if !(height >= 0.04 && height <= 1.5) {
            // Vase mode / non-planar: Z rises continuously, so derive the height
            // from the bead area and a typical 2.25 : 1 width-to-height ratio.
            height = beadArea > 0 ? (beadArea / 2.25).squareRoot() : 0.2
        }
        height = min(max(height, 0.04), 1.5)

        var width: Float = 0.45
        if beadArea > 0 { width = beadArea / height }
        width = min(max(width, 0.3), 1.5)

        return ParsedGCode(moves: moves, layerHeight: height, lineWidth: width)
    }
}
