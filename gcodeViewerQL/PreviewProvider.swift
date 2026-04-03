import Cocoa
import Quartz

/// Quick Look Preview Extension for .gcode files.
///
/// Pipeline:
///   URL → GCodeParser → SurfaceExtractor → MeshBuilder → SCNRenderer → NSImage → QLPreviewReply
///
/// The extension runs in its own sandboxed XPC process. It shares source files
/// with the main app target (GCodeParser, SurfaceExtractor, MeshBuilder, Move)
/// but has no runtime connection to the app.
class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// Canvas size for the rendered snapshot (points, not pixels).
    private let canvasSize = CGSize(width: 1200, height: 900)

    // MARK: - QLPreviewingController

    /// Called by Quick Look to produce a preview for `url`.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {

        let url = request.fileURL

        // Acquire sandbox access for the URL delivered by the system.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // ── 1. Parse ─────────────────────────────────────────────────────────
        let moves = try await GCodeParser.parse(url: url) { _ in }

        // ── 2. Voxelise + extract surface ────────────────────────────────────
        // Use a coarser voxel size (1 mm) so the preview generates quickly.
        let voxels = await SurfaceExtractor.extract(moves: moves, voxelSize: 1.0) { _ in }

        // ── 3. Build mesh ────────────────────────────────────────────────────
        let geometry = await MeshBuilder.build(
            surfaceVoxels: voxels,
            voxelSize: 1.0,
            color: NSColor(red: 0.75, green: 0.75, blue: 0.80, alpha: 1)
        )

        // ── 4. Render to NSImage ─────────────────────────────────────────────
        let image = GCodeSnapshotRenderer.render(geometry: geometry, size: canvasSize)

        // ── 5. Return QLPreviewReply with the PNG data ───────────────────────
        let reply = QLPreviewReply(dataOfContentType: .png, contentSize: canvasSize) { _ in
            guard let tiffData = image.tiffRepresentation,
                  let bitmap   = NSBitmapImageRep(data: tiffData),
                  let pngData  = bitmap.representation(using: .png, properties: [:])
            else {
                throw CocoaError(.fileReadUnknown)
            }
            return pngData
        }
        return reply
    }
}
