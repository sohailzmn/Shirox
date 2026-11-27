import SwiftUI

/// Full-screen poster lightbox: the hero artwork shown uncropped over a dimmed
/// backdrop, with pinch/double-tap zoom on iOS and drag-down to dismiss.
///
/// The caller supplies the image so the viewer enlarges *the same source the hero
/// showed* (TVDB art where AniList resolved it, the module's image otherwise)
/// rather than re-deriving a URL that could differ.
struct PosterViewer<Content: View>: View {
    @Binding var isPresented: Bool
    private let content: Content

    /// Vertical travel at which releasing dismisses.
    private static var dismissDistance: CGFloat { 180 }

    @State private var dragOffset: CGSize = .zero
    @State private var zoomScale: CGFloat = 1

    init(isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        _isPresented = isPresented
        self.content = content()
    }

    /// 0 at rest, 1 once dragged far enough that releasing dismisses. Drives the
    /// backdrop fade and the shrink-toward-the-finger feel.
    private var dismissProgress: CGFloat {
        min(1, abs(dragOffset.height) / Self.dismissDistance)
    }

    /// The scroll view only pans once zoomed in, so drag-to-dismiss is safe to run
    /// simultaneously below this threshold and must stand down above it.
    private var isZoomed: Bool { zoomScale > 1.01 }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(dismissProgress) * 0.55)
                .ignoresSafeArea()

            zoomableContent
                .scaleEffect(1 - dismissProgress * 0.15)
                .offset(dragOffset)

            closeButton
                .opacity(1 - Double(dismissProgress))
        }
        #if !os(tvOS)
        .simultaneousGesture(dismissDrag)
        #endif
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 720)
        .onExitCommand { dismiss() }
        #endif
    }

    // MARK: - Content

    @ViewBuilder
    private var zoomableContent: some View {
        #if os(iOS)
        // Reuse the reader's UIScrollView-backed zoom rather than a second
        // implementation; `onZoomChange` is what lets the drag stand down.
        ZoomableContainer(
            onSingleTap: { if !isZoomed { dismiss() } },
            onZoomChange: { zoomScale = $0 }
        ) {
            content.padding(.horizontal, 12)
        }
        .ignoresSafeArea()
        #else
        content
            .padding(24)
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
        #endif
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close poster")

                Spacer()
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Drag to dismiss

    #if !os(tvOS)
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isZoomed else { return }
                if abs(value.translation.height) > Self.dismissDistance * 0.55 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                }
            }
    }
    #endif

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Call-site modifier

private struct ExpandablePosterModifier<Poster: View>: ViewModifier {
    @ViewBuilder let poster: () -> Poster
    @State private var isPresented = false

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .contentShape(Rectangle())
            .onTapGesture { isPresented = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows the full poster")
            .fullPosterCover(isPresented: $isPresented, poster: poster)
        #endif
    }
}

extension View {
    /// Makes a hero poster tappable, opening the full artwork over the screen.
    /// No-op on tvOS, which drives everything through the focus engine and has no
    /// tap gesture to hang this on.
    func expandablePoster<Poster: View>(@ViewBuilder poster: @escaping () -> Poster) -> some View {
        modifier(ExpandablePosterModifier(poster: poster))
    }

    /// `fullScreenCover` where it exists, `sheet` on macOS where it doesn't.
    @ViewBuilder
    fileprivate func fullPosterCover<Poster: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder poster: @escaping () -> Poster
    ) -> some View {
        #if os(macOS)
        self.sheet(isPresented: isPresented) {
            PosterViewer(isPresented: isPresented, content: poster)
        }
        #else
        self.fullScreenCover(isPresented: isPresented) {
            PosterViewer(isPresented: isPresented, content: poster)
        }
        #endif
    }
}
