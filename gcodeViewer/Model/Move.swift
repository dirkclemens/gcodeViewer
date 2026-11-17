import simd

/// Represents a single parsed G-code linear move command.
nonisolated struct Move: Sendable {
    /// Start position of this move in millimetres (absolute coordinates).
    /// This is where the nozzle was *before* this command executed.
    let from: SIMD3<Float>
    /// End position of this move in millimetres (absolute coordinates).
    let position: SIMD3<Float>
    /// Whether material is extruded during this move (i.e. E increases).
    let isExtrusion: Bool
    /// Zero-based layer index (increments each time an extrusion starts at a higher Z).
    let layerIndex: Int
}

/// Output of `GCodeParser`: the move list plus the bead dimensions estimated
/// from the file, which the voxeliser needs to close the gaps between
/// neighbouring extrusion lines at any voxel size.
nonisolated struct ParsedGCode: Sendable {
    let moves: [Move]
    /// Estimated layer height in millimetres.
    let layerHeight: Float
    /// Estimated extrusion (bead) width in millimetres.
    let lineWidth: Float
}
