//
//  PhotoDetailView.swift
//  PocketPic
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct PhotoDetailView: View {
    let photo: Photo
    @EnvironmentObject var photoStore: PhotoStore
    @Environment(\.dismiss) private var dismiss

    @State private var image: PlatformImage?
    @State private var isLoading = true
    @State private var showDeleteConfirm = false

    // Zoom / pan state
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            } else if let img = image {
                photoContent(img)
            } else {
                Label("Could not load photo", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            overlayControls
        }
        #if canImport(UIKit)
        .statusBarHidden()
        #endif
        .task {
            isLoading = true
            image = await photoStore.loadImageAsync(for: photo)
            isLoading = false
        }
        .confirmationDialog(
            "Delete Photo",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                photoStore.deletePhoto(photo)
                dismiss()
            }
        } message: {
            Text("This will permanently remove the photo from your library.")
        }
    }

    // MARK: - Photo content with pinch + pan

    @ViewBuilder
    private func photoContent(_ img: PlatformImage) -> some View {
        #if canImport(UIKit)
        let swiftImage = Image(uiImage: img)
        #elseif canImport(AppKit)
        let swiftImage = Image(nsImage: img)
        #endif

        swiftImage
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { delta in
                        let newScale = baseScale * delta
                        scale = max(1, min(newScale, 8))
                    }
                    .onEnded { _ in
                        baseScale = scale
                        if scale <= 1 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                resetZoom()
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: baseOffset.width + value.translation.width,
                            height: baseOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        baseOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    if scale > 1 { resetZoom() } else { scale = 3; baseScale = 3 }
                }
            }
    }

    // MARK: - Overlay: close + date + delete

    private var overlayControls: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }

                Spacer()

                Text(photo.date, format: .dateTime.year().month(.abbreviated).day())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Spacer()
        }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
