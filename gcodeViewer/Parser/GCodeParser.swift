import Foundation
import simd

enum GCodeParser {

    // MARK: - Public API

    nonisolated static func parse(
        url: URL,
        progressHandler: @escaping @Sendable (Double) async -> Void
    ) async throws -> [Move] {

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        return await Task.detached(priority: .userInitiated) {
            var moves: [Move] = []
            moves.reserveCapacity(100_000)

            var currentPos      = SIMD3<Float>(0, 0, 0)
            var prevE: Float    = 0
            var eOffset: Float  = 0
            var layerIndex      = 0
            var lastPrintZ: Float = 0          // only updated on extrusion; detects Z-hop
            var isRelativeMove  = false
            var isRelativeExtr  = false
            var hasStartedPrinting = false     // true after first extrusion move
            var lineCount       = 0
            var bytesRead       = 0

            let newline   = UInt8(ascii: "\n")
            var lineStart = data.startIndex

            while lineStart < data.endIndex {
                let lineEnd  = data[lineStart...].firstIndex(of: newline) ?? data.endIndex
                let lineData = data[lineStart..<lineEnd]
                lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
                bytesRead += lineData.count + 1
                lineCount += 1

                guard let rawLine = String(bytes: lineData, encoding: .utf8) else { continue }

                // Strip comment and uppercase the whole line for case-insensitive parsing
                let stripped: String
                if let semi = rawLine.firstIndex(of: ";") {
                    stripped = String(rawLine[..<semi]).trimmingCharacters(in: .whitespaces)
                } else {
                    stripped = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !stripped.isEmpty else { continue }
                let line = stripped.uppercased()

                let spaceIdx = line.firstIndex(of: " ") ?? line.endIndex
                let command  = String(line[..<spaceIdx])

                switch command {

                case "G28":
                    currentPos  = .zero
                    prevE       = 0
                    eOffset     = 0
                    layerIndex  = 0
                    lastPrintZ  = 0

                case "G90": isRelativeMove = false
                case "G91": isRelativeMove = true
                case "M82": isRelativeExtr = false
                case "M83": isRelativeExtr = true

                case "G92":
                    if let eVal = parseParam("E", from: line) {
                        if eVal == 0 && !hasStartedPrinting {
                            // Preamble reset — discard accumulated travel moves
                            moves.removeAll(keepingCapacity: true)
                            currentPos = .zero
                            prevE      = 0
                            eOffset    = 0
                            layerIndex = 0
                            lastPrintZ = 0
                        } else {
                            // Mid-print extruder reset (e.g. Marlin relative-mode reset)
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

                    var isExtrusion = false
                    if let eVal = eP {
                        let absE = isRelativeExtr ? prevE + eVal : eVal + eOffset
                        if absE > prevE { isExtrusion = true }
                        prevE = absE
                    }

                    if isExtrusion {
                        hasStartedPrinting = true
                        if newZ > lastPrintZ {
                            layerIndex += 1
                            lastPrintZ = newZ
                        }
                    }

                    moves.append(Move(
                        from:        currentPos,
                        position:    newPos,
                        isExtrusion: isExtrusion,
                        layerIndex:  layerIndex
                    ))
                    currentPos = newPos

                case "G2", "G3":
                    let xP = parseParam("X", from: line)
                    let yP = parseParam("Y", from: line)
                    let zP = parseParam("Z", from: line)
                    let iP = parseParam("I", from: line)
                    let jP = parseParam("J", from: line)
                    let eP = parseParam("E", from: line)

                    let endX = isRelativeMove ? currentPos.x + (xP ?? 0) : (xP ?? currentPos.x)
                    let endY = isRelativeMove ? currentPos.y + (yP ?? 0) : (yP ?? currentPos.y)
                    let endZ = isRelativeMove ? currentPos.z + (zP ?? 0) : (zP ?? currentPos.z)
                    let endPos = SIMD3<Float>(endX, endY, endZ)

                    var isExtrusion = false
                    if let eVal = eP {
                        let absE = isRelativeExtr ? prevE + eVal : eVal + eOffset
                        if absE > prevE { isExtrusion = true }
                        prevE = absE
                    }

                    let cx = currentPos.x + (iP ?? 0)
                    let cy = currentPos.y + (jP ?? 0)

                    let arcMoves = linearizeArc(
                        from:        currentPos,
                        to:          endPos,
                        center:      SIMD2<Float>(cx, cy),
                        clockwise:   command == "G2",
                        isExtrusion: isExtrusion,
                        layerIndex:  layerIndex
                    )

                    if isExtrusion {
                        hasStartedPrinting = true
                        if endZ > lastPrintZ {
                            layerIndex += 1
                            lastPrintZ = endZ
                        }
                    }

                    moves.append(contentsOf: arcMoves)
                    currentPos = endPos

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

    // MARK: - Arc linearization

    nonisolated private static func linearizeArc(
        from:        SIMD3<Float>,
        to:          SIMD3<Float>,
        center:      SIMD2<Float>,
        clockwise:   Bool,
        isExtrusion: Bool,
        layerIndex:  Int
    ) -> [Move] {

        let cx = center.x, cy = center.y
        let radius = hypot(from.x - cx, from.y - cy)
        guard radius > 0 else { return [] }

        let startAngle = atan2(from.y - cy, from.x - cx)
        var endAngle   = atan2(to.y   - cy, to.x   - cx)

        var span: Float
        if clockwise {
            if endAngle >= startAngle { endAngle -= 2 * .pi }
            span = startAngle - endAngle
        } else {
            if endAngle <= startAngle { endAngle += 2 * .pi }
            span = endAngle - startAngle
        }
        span = abs(span)
        guard span > 0 else { return [] }

        let arcLength   = radius * span
        let numSegments = max(1, Int(arcLength / 0.5))   // ~0.5 mm segments
        let dz          = (to.z - from.z) / Float(numSegments)

        var result: [Move] = []
        result.reserveCapacity(numSegments)
        var prev = from

        for i in 1...numSegments {
            let t     = Float(i) / Float(numSegments)
            let angle = clockwise
                ? startAngle - span * t
                : startAngle + span * t
            let next  = SIMD3<Float>(
                cx + radius * cos(angle),
                cy + radius * sin(angle),
                from.z + dz * Float(i)
            )
            result.append(Move(from: prev, position: next,
                               isExtrusion: isExtrusion, layerIndex: layerIndex))
            prev = next
        }
        return result
    }

    // MARK: - Parameter parsing

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
