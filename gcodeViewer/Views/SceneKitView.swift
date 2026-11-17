import SwiftUI
import SceneKit
import AppKit

/// SwiftUI wrapper around `GCodeSCNView` (camera controls, framing and the
/// light rig live there, shared with the Quick Look preview).
struct SceneKitView: NSViewRepresentable {

    var scene: SCNScene?
    var shouldResetCamera: Bool

    func makeNSView(context: Context) -> GCodeSCNView {
        let view = GCodeSCNView()
        view.configureViewport()
        return view
    }

    func updateNSView(_ nsView: GCodeSCNView, context: Context) {
        guard let scene else {
            nsView.scene = nil
            return
        }

        if nsView.scene !== scene {
            nsView.scene = scene
            // Defer framing by one runloop cycle so SceneKit has rendered one frame
            // and bounding boxes are fully computed before we read them.
            DispatchQueue.main.async { nsView.frameContent() }
        }

        if shouldResetCamera {
            DispatchQueue.main.async { nsView.frameContent() }
        }
    }
}
