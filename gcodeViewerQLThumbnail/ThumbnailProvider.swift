import AppKit
import QuickLookThumbnailing
import SceneKit

/// Quick Look Thumbnail Extension for .gcode files (Finder icons, Get Info,
/// column-view preview, Spotlight).
///
/// Same pipeline as the preview extension, tuned for many small images:
/// coarser voxels for small icons, a transparent background, and lighter
/// antialiasing (Finder scales the image down anyway).
nonisolated final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // QLThumbnailProvider only offers this completion-handler API; bridge
        // it to the async pipeline once, here.
        let url     = request.fileURL
        let maxSize = request.maximumSize
        let scale   = request.scale
        nonisolated(unsafe) let reply = handler

        Task {
            do {
                reply(try await Self.makeReply(url: url, maxSize: maxSize, scale: scale), nil)
            } catch {
                reply(nil, error)
            }
        }
    }

    private static func makeReply(url: URL, maxSize: CGSize, scale: CGFloat) async throws -> QLThumbnailReply {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // Icons up to ~128 pt don't show sub-millimetre detail; a coarser grid
        // keeps Finder responsive when it requests dozens of thumbnails at once.
        let side      = min(maxSize.width, maxSize.height)
        let voxelSize: Float = side <= 128 ? 0.8 : 0.5

        let model = try await GCodeParser.parse(url: url) { _ in }
        let grid  = await SurfaceExtractor.extract(model: model, voxelSize: voxelSize) { _ in }
        let mesh  = await MeshBuilder.build(grid: grid)
        guard !mesh.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        let size      = CGSize(width: side, height: side)
        let pixelSize = CGSize(width: (side * scale).rounded(), height: (side * scale).rounded())
        guard let image = GCodeSnapshotRenderer.render(
            mesh: mesh,
            pixelSize: pixelSize,
            background: .clear,
            antialiasing: .multisampling2X
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        return QLThumbnailReply(contextSize: size) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            return true
        }
    }
}
