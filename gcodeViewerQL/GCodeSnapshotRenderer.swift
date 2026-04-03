import SceneKit
import AppKit

/// Renders an SCNGeometry to an NSImage using an offscreen SCNRenderer.
/// Used by the Quick Look extension to produce a static preview image.
enum GCodeSnapshotRenderer {

    /// Render `geometry` into an image of `size` points at 2× retina scale.
    nonisolated static func render(geometry: SCNGeometry, size: CGSize) -> NSImage {
        let scale: CGFloat = 2
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)

        // ── Scene setup ───────────────────────────────────────────────────────
        let scene    = SCNScene()
        let meshNode = SCNNode(geometry: geometry)

        // Centre the mesh at the origin (same logic as the main app).
        let (minB, maxB) = meshNode.boundingBox
        let cx = (minB.x + maxB.x) / 2
        let cy = (minB.y + maxB.y) / 2
        let cz = (minB.z + maxB.z) / 2
        meshNode.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)
        scene.rootNode.addChildNode(meshNode)

        // ── Lights ────────────────────────────────────────────────────────────
        let ambient = SCNLight()
        ambient.type      = .ambient
        ambient.intensity = 200
        let ambientNode   = SCNNode(); ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type      = .directional
        key.intensity = 900
        let keyNode   = SCNNode(); keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 5, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type      = .directional
        fill.intensity = 300
        fill.color     = NSColor(white: 0.8, alpha: 1)
        let fillNode   = SCNNode(); fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)
        scene.rootNode.addChildNode(fillNode)

        // ── Camera ────────────────────────────────────────────────────────────
        let dx       = Float(maxB.x - minB.x)
        let dy       = Float(maxB.y - minB.y)
        let dz       = Float(maxB.z - minB.z)
        let radius   = sqrt(dx*dx + dy*dy + dz*dz) / 2
        let distance = radius * 2.5

        let camera       = SCNCamera()
        camera.zNear     = Double(radius) * 0.001
        camera.zFar      = Double(radius) * 20
        let cameraNode   = SCNNode()
        cameraNode.camera = camera

        // Isometric-ish angle: front-left-above
        let angle: Float = .pi / 6         // 30°
        cameraNode.position = SCNVector3(
            -distance * sin(angle),
             distance * 0.4,
             distance * cos(angle)
        )
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // ── Offscreen renderer ────────────────────────────────────────────────
        guard let device = MTLCreateSystemDefaultDevice() else {
            return NSImage(size: size)   // fallback blank image
        }
        let renderer          = SCNRenderer(device: device, options: nil)
        renderer.scene        = scene
        renderer.pointOfView  = cameraNode
        renderer.autoenablesDefaultLighting = false

        // Create a Metal texture to render into.
        let descriptor               = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width:  Int(pixelSize.width),
            height: Int(pixelSize.height),
            mipmapped: false
        )
        descriptor.usage             = [.renderTarget, .shaderRead]
        descriptor.storageMode       = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return NSImage(size: size)
        }

        let renderPassDescriptor                            = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture   = texture
        renderPassDescriptor.colorAttachments[0].loadAction  = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor =
            MTLClearColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)

        guard let commandQueue  = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return NSImage(size: size)
        }

        renderer.render(
            atTime: 0,
            viewport: CGRect(origin: .zero, size: pixelSize),
            commandBuffer: commandBuffer,
            passDescriptor: renderPassDescriptor
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // ── Texture → NSImage ─────────────────────────────────────────────────
        let bytesPerRow  = Int(pixelSize.width) * 4
        var rawBytes     = [UInt8](repeating: 0, count: bytesPerRow * Int(pixelSize.height))
        texture.getBytes(
            &rawBytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size:   MTLSize(width: Int(pixelSize.width),
                                height: Int(pixelSize.height), depth: 1)
            ),
            mipmapLevel: 0
        )

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context    = CGContext(
                  data: &rawBytes,
                  width:            Int(pixelSize.width),
                  height:           Int(pixelSize.height),
                  bitsPerComponent: 8,
                  bytesPerRow:      bytesPerRow,
                  space:            colorSpace,
                  bitmapInfo:       CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cgImage = context.makeImage()
        else {
            return NSImage(size: size)
        }

        let nsImage = NSImage(size: size)
        nsImage.addRepresentation(
            NSBitmapImageRep(cgImage: cgImage)
        )
        return nsImage
    }
}
