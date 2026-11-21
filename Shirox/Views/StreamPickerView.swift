import SwiftUI

struct StreamPickerView: View {
    @ObservedObject var vm: DetailViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoadingStreams {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Videos werden geprüft …")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.needsCloudflareVerification {
                    CloudflareVerifyView { vm.verifyCloudflare() }
                } else if vm.streamOptions.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Stream Unavailable",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text(vm.errorMessage
                                ?? "Could not find any playable streams for this episode.")
                        )
                        if let episode = vm.selectedEpisode {
                            Button("Erneut versuchen") { vm.loadStreams(for: episode) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    List(vm.streamOptions, id: \.url) { stream in
                        Button {
                            vm.pickStream(stream)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .softScrollEdges()
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #elseif !os(tvOS)
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle(episodeTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { vm.cancelStreamLoading() }
                }
            }
            .tint(.primary)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 320)
        #else
        .adaptivePresentationDetents([.medium, .large])
        #endif
    }

    private var episodeTitle: String {
        vm.selectedEpisode.map { "Episode \($0.displayNumber)" } ?? "Select Stream"
    }
}

// MARK: - Shared Cloudflare verification UI

/// Full-screen "Verify Cloudflare" prompt shown when a fetch hit a Turnstile wall.
/// `onVerify` should run the (user-initiated) challenge and retry.
struct CloudflareVerifyView: View {
    let onVerify: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Website-Prüfung erforderlich")
                    .font(.headline)
                Text("Diese Quelle verlangt eine Website-Prüfung. Nutze eine andere verfügbare Quelle.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onVerify) {
                Label("Website prüfen", systemImage: "checkmark.shield")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compact inline "Verify Cloudflare" button for module-picker rows.
struct CloudflareVerifyInlineButton: View {
    let onVerify: () -> Void

    var body: some View {
        Button(action: onVerify) {
            Label("Website prüfen", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.orange)
    }
}
