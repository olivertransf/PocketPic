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

struct PhotoViewerView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: Photo.ID?
    @EnvironmentObject private var photoStore: PhotoStore
    @Environment(\.dismiss) private var dismiss

    @State private var isZoomed = false
    @State private var showDeleteConfirm = false

    private var sortedPhotos: [Photo] {
        photos.sorted { $0.date > $1.date }
    }

    private var currentPhoto: Photo? {
        guard let selectedPhotoID else { return nil }
        return sortedPhotos.first { $0.id == selectedPhotoID }
    }

    private var currentIndex: Int {
        guard let selectedPhotoID,
              let index = sortedPhotos.firstIndex(where: { $0.id == selectedPhotoID }) else {
            return 0
        }
        return index
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if sortedPhotos.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo")
                        .foregroundStyle(.white)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(sortedPhotos) { photo in
                                PhotoPageView(photo: photo, isZoomed: $isZoomed)
                                    .containerRelativeFrame(.horizontal)
                                    .id(photo.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selectedPhotoID)
                    .scrollDisabled(isZoomed)
                    .ignoresSafeArea()
                }
            }
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.55), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #elseif os(macOS)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbarBackground(Color.black.opacity(0.85), for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            #endif
            .toolbar { viewerToolbar }
        }
        #if canImport(UIKit)
        .statusBarHidden()
        #endif
        .onAppear(perform: ensureSelection)
        .onChange(of: selectedPhotoID) { _, _ in
            isZoomed = false
        }
        .onChange(of: photoStore.photos.count) { _, _ in
            guard !sortedPhotos.isEmpty else {
                dismiss()
                return
            }
            if selectedPhotoID == nil || !sortedPhotos.contains(where: { $0.id == selectedPhotoID }) {
                let index = min(currentIndex, sortedPhotos.count - 1)
                selectedPhotoID = sortedPhotos[index].id
            }
        }
        #if os(macOS)
        .onKeyPress(.leftArrow) {
            step(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(by: 1)
            return .handled
        }
        #endif
        .confirmationDialog(
            "Delete Photo",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let photo = currentPhoto else { return }
                photoStore.deletePhoto(photo)
                if sortedPhotos.isEmpty {
                    dismiss()
                }
            }
        } message: {
            Text("This will permanently remove the photo from your library.")
        }
    }

    @ToolbarContentBuilder
    private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") {
                dismiss()
            }
        }

        ToolbarItem(placement: .principal) {
            if let photo = currentPhoto {
                VStack(spacing: 2) {
                    Text(photo.date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.subheadline.weight(.semibold))
                    if sortedPhotos.count > 1 {
                        Text("\(currentIndex + 1) of \(sortedPhotos.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    private func ensureSelection() {
        if selectedPhotoID == nil {
            selectedPhotoID = sortedPhotos.first?.id
        }
    }

    private func step(by offset: Int) {
        let next = currentIndex + offset
        guard sortedPhotos.indices.contains(next) else { return }
        selectedPhotoID = sortedPhotos[next].id
    }
}

private struct PhotoPageView: View {
    let photo: Photo
    @Binding var isZoomed: Bool
    @EnvironmentObject private var photoStore: PhotoStore

    @State private var image: PlatformImage?
    @State private var isLoading = true
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let image {
                photoContent(image)
            } else {
                ContentUnavailableView(
                    "Could Not Load Photo",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.white)
            }
        }
        .task(id: photo.id) {
            isLoading = true
            resetZoom()
            image = await photoStore.loadImageAsync(for: photo)
            isLoading = false
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
            .gesture(zoomGesture)
            .simultaneousGesture(isZoomed ? panGesture : nil)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    if scale > 1 {
                        resetZoom()
                    } else {
                        scale = 2.5
                        baseScale = 2.5
                        isZoomed = true
                    }
                }
            }
            .onChange(of: scale) { _, newScale in
                isZoomed = newScale > 1.01
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { delta in
                let newScale = baseScale * delta
                scale = max(1, min(newScale, 8))
                isZoomed = scale > 1.01
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        resetZoom()
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                offset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
        isZoomed = false
    }
}
