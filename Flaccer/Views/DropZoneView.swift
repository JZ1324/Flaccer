import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @ObservedObject var viewModel: FileScanViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 54, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.teal)

            VStack(spacing: 8) {
                Text("Drop Audio Here")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("FLAC, WAV, AIFF, ALAC, MP3, AAC")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.showOpenPanel()
            } label: {
                Label("Choose Files or Folders", systemImage: "folder.badge.plus")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isTargeted ? Color.teal : Color.white.opacity(0.12), lineWidth: isTargeted ? 2 : 1)
                )
        )
        .padding(32)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            viewModel.handleDrop(providers: providers)
            return true
        }
    }
}
