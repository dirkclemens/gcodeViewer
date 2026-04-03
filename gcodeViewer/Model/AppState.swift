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
            // Acquire sandbox access. URLs from application(_:open:) and from
            // security-scoped bookmarks require this; NSOpenPanel/fileImporter
            // URLs also accept it safely (startAccessing returns false but that
            // is harmless — we still stop in the defer).
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

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

                // Read XY extents before applying the pivot so we have raw print-space coords.
                let (minB, maxB) = node.boundingBox

                // Centre the model at origin for nicer default camera framing.
                let centre = SCNVector3(
                    (minB.x + maxB.x) / 2,
                    (minB.y + maxB.y) / 2,
                    (minB.z + maxB.z) / 2
                )
                node.pivot = SCNMatrix4MakeTranslation(centre.x, centre.y, centre.z)
                newScene.rootNode.addChildNode(node)

                // Add the grid at Z = 0.  Because the mesh node is centred around
                // the XY midpoint via its pivot, we need to shift the grid by the
                // same XY offset so it still aligns with the object footprint.
                let gridNode = GridBuilder.build(
                    minX: Float(minB.x - centre.x),
                    maxX: Float(maxB.x - centre.x),
                    minY: Float(minB.y - centre.y),
                    maxY: Float(maxB.y - centre.y)
                )
                // The grid sits at the bottom face of the object (minB.z shifted by pivot).
                gridNode.position = SCNVector3(0, 0, minB.z - centre.z)
                newScene.rootNode.addChildNode(gridNode)

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
        // Target the mesh node specifically (not the grid node).
        for node in scene.rootNode.childNodes where node.name != "grid" {
            node.geometry?.materials.first?.diffuse.contents = nsColor
        }
    }
}
