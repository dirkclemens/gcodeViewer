import simd

/// Represents a single parsed G-code linear move command.
struct Move: Sendable {
    /// Start position of this move in millimetres (absolute coordinates).
    /// This is where the nozzle was *before* this command executed.
    let from: SIMD3<Float>
    /// End position of this move in millimetres (absolute coordinates).
    let position: SIMD3<Float>
    /// Whether material is extruded during this move (i.e. E increases).
    let isExtrusion: Bool
    /// Zero-based layer index (increments each time Z increases).
    let layerIndex: Int
}
