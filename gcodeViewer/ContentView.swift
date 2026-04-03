import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var state = AppState()
    @State private var showFileImporter = false
    @State private var resetCamera = false

    var body: some View {
        ZStack {
            // ── 3D Viewport ───────────────────────────────────────────────
            if state.scene != nil {
                SceneKitView(scene: state.scene, shouldResetCamera: resetCamera)
                    .ignoresSafeArea()
                    .onChange(of: resetCamera) { _, newVal in
                        if newVal { resetCamera = false }
                    }
            } else if !state.isLoading {
                emptyStateView
            }

            // ── Loading overlay ───────────────────────────────────────────
            if state.isLoading {
                loadingOverlay
            }

            // ── Error banner ──────────────────────────────────────────────
            if let errorMsg = state.errorMessage {
                VStack {
                    errorBanner(errorMsg)
                    Spacer()
                }
            }
        }
        // ── Drag-and-drop ─────────────────────────────────────────────────
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "gcode" else { return }
                Task { @MainActor in state.load(url: url) }
            }
            return true
        }
        // ── File importer ─────────────────────────────────────────────────
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [gcodeUTType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                state.load(url: url)
            case .failure(let error):
                state.errorMessage = error.localizedDescription
            }
        }
        // ── Toolbar ───────────────────────────────────────────────────────
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Open…", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Open a .gcode file (⌘O)")
            }

            ToolbarItem {
                Button {
                    resetCamera = true
                } label: {
                    Label("Reset Camera", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(state.scene == nil)
                .help("Reset camera to default view")
            }

            ToolbarItem {
                Divider()
            }

            ToolbarItem {
                HStack(spacing: 6) {
                    Text("Voxel:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Slider(value: $state.voxelSize, in: 0.1...2.5, step: 0.1)
                        .frame(width: 110)
                        .help("Voxel resolution — smaller = more detail, slower")
                    Text(String(format: "%.1f mm", state.voxelSize))
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .leading)
                }
            }

            ToolbarItem {
                Button {
                    guard let url = state.fileURL else { return }
                    state.load(url: url)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(state.fileURL == nil || state.isLoading)
                .help("Re-process file with current voxel size")
            }

            ToolbarItem {
                ColorPicker("Colour", selection: $state.objectColor, supportsOpacity: false)
                    .help("Object colour")
                    .onChange(of: state.objectColor) { _, _ in
                        state.recolour()
                    }
            }
        }
        .navigationTitle(state.fileURL?.lastPathComponent ?? "GCode Viewer")
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Sub-views

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.quaternary)
            VStack(spacing: 6) {
                Text("No file loaded")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Open or drag a .gcode file to render the surface")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Button("Open File…") {
                showFileImporter = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                Text(state.loadingPhase)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") {
                state.errorMessage = nil
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    // MARK: - Helpers

    /// UTType for .gcode files (not in the system registry, so we declare it).
    private var gcodeUTType: UTType {
        UTType(filenameExtension: "gcode") ?? .data
    }
}

#Preview {
    ContentView()
}
