import Foundation
import simd

/// Streams a G-code file line-by-line and produces an array of Move values.
///
/// Handles:
///  - G0 / G1 linear moves
///  - G90 / G91 absolute / relative positioning
///  - G92 position reset
///  - M82 / M83 absolute / relative extrusion mode
///  - Inline comments (`;`)
///  - Both LF and CRLF line endings
///
/// Header suppression:
///  The parser does a single pass. Every time it encounters a bare "G92 E0"
///  (extruder reset to zero) it discards all moves collected so far and resets
///  position state. This means that after the loop finishes, `moves` contains
///  only what was printed after the *last* G92 E0 — which is always the
///  start-of-print reset that slicers emit immediately before the first layer,
///  regardless of how many G92 E0 lines appear in the startup script.
enum GCodeParser {

    // MARK: - Public API

    /// Parse a G-code file at `url`.
    /// - Parameter progressHandler: Called periodically with a value in [0, 1].
    /// - Returns: Array of Move values (extrusion and travel), starting after
    ///            the last G92 E0 in the file.
    nonisolated static func parse(
        url: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> [Move] {

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        return await Task.detached(priority: .userInitiated) {

            var moves: [Move] = []
            moves.reserveCapacity(100_000)

            // ── Parser state ───────────────────────────────────────────────
            var currentPos      = SIMD3<Float>(0, 0, 0)
            var prevE: Float    = 0
            var eOffset: Float  = 0
            var layerIndex      = 0
            var isRelativeMove  = false
            var isRelativeExtr  = false
            var lineCount       = 0
            var bytesRead       = 0

            let newline  = UInt8(ascii: "\n")
            var lineStart = data.startIndex

            while lineStart < data.endIndex {

                // ── Slice one line from the buffer ─────────────────────────
                let lineEnd  = data[lineStart...].firstIndex(of: newline) ?? data.endIndex
                let lineData = data[lineStart..<lineEnd]
                lineStart = lineEnd < data.endIndex
                    ? data.index(after: lineEnd)
                    : data.endIndex

                bytesRead += lineData.count + 1
                lineCount += 1

                guard let rawLine = String(bytes: lineData, encoding: .utf8) else { continue }

                // ── Strip inline comment and whitespace ────────────────────
                let line: String
                if let semi = rawLine.firstIndex(of: ";") {
                    line = String(rawLine[..<semi]).trimmingCharacters(in: .whitespaces)
                } else {
                    line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !line.isEmpty else { continue }

                // ── Extract command word ───────────────────────────────────
                let spaceIdx = line.firstIndex(of: " ") ?? line.endIndex
                let command  = String(line[..<spaceIdx]).uppercased()

                // ── Dispatch ───────────────────────────────────────────────
                switch command {

                case "G28":
                    // Home: physical position is now (0,0,0).
                    currentPos = .zero
                    prevE      = 0
                    eOffset    = 0
                    layerIndex = 0

                case "G90": isRelativeMove = false
                case "G91": isRelativeMove = true
                case "M82": isRelativeExtr = false
                case "M83": isRelativeExtr = true

                case "G92":
                    // G92 E0 — extruder reset.
                    // If this resets E to zero (the common form), treat it as
                    // the potential start-of-print marker: flush all moves
                    // collected so far and reset positional state so the next
                    // move starts cleanly. Non-E or non-zero G92 just update
                    // the offset as normal.
                    if let eVal = parseParam("E", from: line) {
                        if eVal == 0 {
                            // Discard everything accumulated before this point.
                            moves.removeAll(keepingCapacity: true)
                            currentPos = .zero
                            prevE      = 0
                            eOffset    = 0
                            layerIndex = 0
                        } else {
                            eOffset = prevE - eVal
                        }
                    }

                case "G0", "G1":
                    let xP = parseParam("X", from: line)
                    let yP = parseParam("Y", from: line)
                    let zP = parseParam("Z", from: line)
                    let eP = parseParam("E", from: line)

                    let newX, newY, newZ: Float
                    if isRelativeMove {
                        newX = currentPos.x + (xP ?? 0)
                        newY = currentPos.y + (yP ?? 0)
                        newZ = currentPos.z + (zP ?? 0)
                    } else {
                        newX = xP ?? currentPos.x
                        newY = yP ?? currentPos.y
                        newZ = zP ?? currentPos.z
                    }
                    let newPos = SIMD3<Float>(newX, newY, newZ)

                    if newZ > currentPos.z { layerIndex += 1 }

                    var isExtrusion = false
                    if let eVal = eP {
                        let absE = isRelativeExtr ? prevE + eVal : eVal + eOffset
                        if absE > prevE { isExtrusion = true }
                        prevE = absE
                    }

                    moves.append(Move(
                        from:        currentPos,
                        position:    newPos,
                        isExtrusion: isExtrusion,
                        layerIndex:  layerIndex
                    ))
                    currentPos = newPos

                default:
                    break
                }

                if lineCount % 2000 == 0 {
                    let p = min(Double(bytesRead) / Double(fileSize), 1.0)
                    await progressHandler(p)
                }
            }

            return moves
        }.value
    }

    // MARK: - Private helpers

    /// Extract a named parameter value from a G-code line.
    /// e.g. `parseParam("X", from: "G1 X10.5 Y3.2")` → `10.5`
    nonisolated private static func parseParam(_ letter: Character, from line: String) -> Float? {
        guard let idx = line.firstIndex(of: letter) else { return nil }
        let valueStart = line.index(after: idx)
        guard valueStart < line.endIndex else { return nil }

        var end = valueStart
        if line[end] == "-" || line[end] == "+" {
            end = line.index(after: end)
            guard end < line.endIndex else { return nil }
        }
        while end < line.endIndex {
            let c = line[end]
            if c.isNumber || c == "." { end = line.index(after: end) } else { break }
        }
        return Float(line[valueStart..<end])
    }
}
