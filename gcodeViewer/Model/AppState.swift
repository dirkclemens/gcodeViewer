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

    // MARK: - Load pipeline

    func load(url: URL) {
        fileURL = url
        errorMessage = nil
        isLoading = true
        progress = 0.0
        scene = nil

        Task { [self] in
            do {
                loadingPhase = "Parsing G-code…"
                let moves = try await GCodeParser.parse(url: url) { p in
                    await MainActor.run { self.progress = p * 0.5 }
                }

                loadingPhase = "Extracting surface…"
                let voxelSizeCopy = Float(voxelSize)
                let voxels = await SurfaceExtractor.extract(
                    moves: moves,
                    voxelSize: voxelSizeCopy
                ) { p in
                    await MainActor.run { self.progress = 0.5 + p * 0.3 }
                }

                loadingPhase = "Building mesh…"
                let nsColor = NSColor(objectColor)
                let geometry = await MeshBuilder.build(
                    surfaceVoxels: voxels,
                    voxelSize: voxelSizeCopy,
                    color: nsColor
                )

                loadingPhase = "Done"
                progress = 1.0

                let newScene = SCNScene()
                let node = SCNNode(geometry: geometry)
                // Centre the model at origin for nicer default camera framing
                let (minB, maxB) = node.boundingBox
                let centre = SCNVector3(
                    (minB.x + maxB.x) / 2,
                    (minB.y + maxB.y) / 2,
                    (minB.z + maxB.z) / 2
                )
                node.pivot = SCNMatrix4MakeTranslation(centre.x, centre.y, centre.z)
                newScene.rootNode.addChildNode(node)
                scene = newScene

            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    /// Re-run the mesh build with the current colour (no re-parse needed).
    func recolour() {
        guard let scene else { return }
        let nsColor = NSColor(objectColor)
        scene.rootNode.childNodes.first?.geometry?.materials.first?.diffuse.contents = nsColor
    }
}
