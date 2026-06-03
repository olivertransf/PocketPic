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

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        detailRoot
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

    @ViewBuilder
    private var detailRoot: some View {
        #if canImport(UIKit)
        NavigationStack {
            detailCanvas
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(photo.date, format: .dateTime.year().month(.abbreviated).day())
                            .font(.subheadline.weight(.medium))
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
        }
        .statusBarHidden()
        #else
        NavigationStack {
            detailCanvas
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbarBackground(Color.black.opacity(0.85), for: .windowToolbar)
                .toolbarColorScheme(.dark, for: .windowToolbar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Text(photo.date, format: .dateTime.year().month(.abbreviated).day())
                            .font(.subheadline.weight(.medium))
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
        }
        .pocketPicModalPresentation(.photoDetail)
        #endif
    }

    private var detailCanvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let img = image {
                photoContent(img)
            } else {
                ContentUnavailableView(
                    "Could Not Load Photo",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.white)
            }
        }
    }

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

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}
