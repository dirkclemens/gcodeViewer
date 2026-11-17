import SwiftUI
import SceneKit
import Combine

/// Central observable state for the application.
/// Drives the entire UI from file load through to rendered scene.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var fileURL: URL?
    @Published var scene: SCNScene?
    @Published var isLoading: Bool = false
    @Published var loadingPhase: String = ""
    @Published var progress: Double = 0.0
    @Published var errorMessage: String?

    // MARK: - User-configurable settings (persisted via UserDefaults)

    /// Edge length of each voxel in millimetres. Smaller = more detail, slower.
    @AppStorage("voxelSize") var voxelSize: Double = 0.5

    /// Rendered object colour, stored as a hex string "#RRGGBB".
    @AppStorage("objectColorHex") private var objectColorHex: String = "#BFBFBF"

    /// SwiftUI Color derived from the persisted hex string.
    var objectColor: Color {
        get { Color(hex: objectColorHex) ?? Color(white: 0.75) }
        set {
            objectColorHex = newValue.toHex() ?? "#BFBFBF"
            objectWillChange.send()
        }
    }

    /// Short summary of the rendered mesh (triangle count, effective voxel size).
    @Published var meshInfo: String?

    // MARK: - Load pipeline

    private var loadTask: Task<Void, Never>?
    /// Identifies the most recent `load` call; results of older ones are discarded.
    private var loadGeneration = 0

    func load(url: URL) {
        // A newer request supersedes whatever is still running.
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        fileURL = url
        errorMessage = nil
        meshInfo = nil
        isLoading = true
        progress = 0.0
        loadingPhase = "Parsing G-code…"
        scene = nil

        let requestedVoxelSize = Float(voxelSize)
        let nsColor = NSColor(objectColor)

        loadTask = Task { [self] in
            // Acquire sandbox access. URLs from application(_:open:) and from
            // security-scoped bookmarks require this; NSOpenPanel/fileImporter
            // URLs also accept it safely (startAccessing returns false but that
            // is harmless — we still stop in the defer).
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let model = try await GCodeParser.parse(url: url) { p in
                    await self.report(progress: p * 0.4, generation: generation)
                }
                try Task.checkCancellation()

                loadingPhase = "Voxelising…"
                let grid = await SurfaceExtractor.extract(
                    model: model,
                    voxelSize: requestedVoxelSize
                ) { p in
                    await self.report(progress: 0.4 + p * 0.4, generation: generation)
                }
                try Task.checkCancellation()

                loadingPhase = "Building mesh…"
                let mesh = await MeshBuilder.build(grid: grid)
                try Task.checkCancellation()

                progress = 1.0
                if mesh.isEmpty {
                    errorMessage = "No extrusion moves found in this file."
                } else {
                    scene = SceneBuilder.makeScene(mesh: mesh, color: nsColor)
                    meshInfo = Self.describe(mesh: mesh, grid: grid, requested: requestedVoxelSize)
                }
            } catch is CancellationError {
                return          // superseded — the newer load owns the UI state
            } catch {
                errorMessage = error.localizedDescription
            }
            if generation == loadGeneration { isLoading = false }
        }
    }

    private func report(progress value: Double, generation: Int) {
        guard generation == loadGeneration else { return }
        progress = value
    }

    private static func describe(mesh: MeshData, grid: VoxelGrid, requested: Float) -> String {
        let triangles = mesh.triangleCount.formatted(.number)
        var text = "\(triangles) triangles · \(String(format: "%.2f", grid.voxelSize)) mm voxels"
        if grid.voxelSize > requested * 1.01 {
            text += " (raised from \(String(format: "%.2f", requested)) mm — model too large)"
        }
        return text
    }

    /// Re-run the mesh build with the current colour (no re-parse needed).
    func recolour() {
        guard let scene else { return }
        let nsColor = NSColor(objectColor)
        // Target the mesh node specifically (not the grid node).
        for node in scene.rootNode.childNodes where node.name != SceneBuilder.gridNodeName {
            node.geometry?.materials.first?.diffuse.contents = nsColor
        }
    }
}
