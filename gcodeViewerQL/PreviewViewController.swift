import AppKit
import Quartz
import SceneKit

/// Quick Look Preview Extension for .gcode files (Space bar in Finder).
///
/// View-based preview: the Quick Look panel hosts a live `GCodeSCNView`, so
/// the model can be orbited, panned and zoomed exactly like in the app.
///
/// Pipeline:
///   URL → GCodeParser → SurfaceExtractor → MeshBuilder → SceneBuilder → GCodeSCNView
///
/// The extension runs in its own sandboxed XPC process. It shares source files
/// with the main app target (pipeline, `SceneBuilder`, `GridBuilder`,
/// `GCodeSCNView`) but has no runtime connection to the app.
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Voxel edge length in millimetres used for previews.
    private let voxelSize: Float = 0.5

    private let sceneView = GCodeSCNView()

    override func loadView() {
        sceneView.configureViewport()
        view = sceneView
        preferredContentSize = NSSize(width: 1200, height: 900)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Keyboard shortcuts (F, 1/3/7, ⌘-arrows, +/−) need the view to be first responder.
        view.window?.makeFirstResponder(sceneView)
    }

    // MARK: - QLPreviewingController

    /// Called by Quick Look before the panel shows the view; the panel shows
    /// a spinner until this returns.
    func preparePreviewOfFile(at url: URL) async throws {
        // Acquire sandbox access for the URL delivered by the system.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // ── Parse → voxelise → mesh (all off the main thread) ────────────────
        let model = try await GCodeParser.parse(url: url) { _ in }
        let grid  = await SurfaceExtractor.extract(model: model, voxelSize: voxelSize) { _ in }
        let mesh  = await MeshBuilder.build(grid: grid)
        guard !mesh.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        // ── Scene + camera (bounds are preset, so framing works immediately) ─
        sceneView.scene = SceneBuilder.makeScene(mesh: mesh, color: GCodeSnapshotRenderer.defaultColor)
        sceneView.frameContent()
    }
}
