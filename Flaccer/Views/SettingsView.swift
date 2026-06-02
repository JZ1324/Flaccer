import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: FileScanViewModel

    var body: some View {
        Form {
            Section("Analysis") {
                Stepper(value: $viewModel.concurrencyLimit, in: 1...100) {
                    HStack {
                        Label("Concurrent files", systemImage: "cpu")
                        Spacer()
                        Text("\(viewModel.concurrencyLimit)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("Flaccer can process up to 100 files at once. A smaller value often feels faster for compressed audio because it avoids overloading CPU and disk seeks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Finder") {
                Toggle(isOn: $viewModel.applyFinderTags) {
                    Label("Apply Finder color tags", systemImage: "tag")
                }
            }

            Section("Watch Folder") {
                if let folder = viewModel.watchFolder {
                    LabeledContent("Folder", value: folder.path)
                }

                HStack {
                    Button {
                        viewModel.chooseWatchFolder()
                    } label: {
                        Label("Choose Folder", systemImage: "folder")
                    }

                    Button {
                        viewModel.stopWatching()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .disabled(!viewModel.isWatching)
                }
            }

            Section("Privacy") {
                Label("Local processing only", systemImage: "lock")
                Label("No analytics or network calls", systemImage: "network.slash")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
