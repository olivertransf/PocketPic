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

    @State private var currentIndex = 0
    @State private var isZoomed = false
    @State private var showDeleteConfirm = false

    private var sortedPhotos: [Photo] {
        photos.sorted { $0.date > $1.date }
    }

    private var currentPhoto: Photo? {
        guard sortedPhotos.indices.contains(currentIndex) else { return nil }
        return sortedPhotos[currentIndex]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if sortedPhotos.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo")
                        .foregroundStyle(.white)
                } else {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(sortedPhotos.enumerated()), id: \.element.id) { index, photo in
                            PhotoPageView(photo: photo, isZoomed: $isZoomed)
                                .tag(index)
                        }
                    }
                    #if canImport(UIKit)
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    #endif
                    .disabled(isZoomed)
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
        .onAppear(perform: syncIndexFromSelection)
        .onChange(of: currentIndex) { _, newIndex in
            guard sortedPhotos.indices.contains(newIndex) else { return }
            selectedPhotoID = sortedPhotos[newIndex].id
            isZoomed = false
        }
        .onChange(of: selectedPhotoID) { _, newID in
            guard let newID,
                  let index = sortedPhotos.firstIndex(where: { $0.id == newID }),
                  index != currentIndex else { return }
            currentIndex = index
        }
        .onChange(of: photoStore.photos.count) { _, _ in
            guard !sortedPhotos.isEmpty else {
                dismiss()
                return
            }
            currentIndex = min(currentIndex, sortedPhotos.count - 1)
            selectedPhotoID = sortedPhotos[currentIndex].id
        }
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
            HStack(spacing: 12) {
                if sortedPhotos.count > 1 {
                    Button("Previous", systemImage: "chevron.left") {
                        step(by: -1)
                    }
                    .disabled(currentIndex <= 0)
                    .help("Previous photo")
                    #if os(macOS)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    #endif

                    Button("Next", systemImage: "chevron.right") {
                        step(by: 1)
                    }
                    .disabled(currentIndex >= sortedPhotos.count - 1)
                    .help("Next photo")
                    #if os(macOS)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    #endif
                }

                Button("Delete", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
        }
    }

    private func syncIndexFromSelection() {
        if let id = selectedPhotoID,
           let index = sortedPhotos.firstIndex(where: { $0.id == id }) {
            currentIndex = index
        }
    }

    private func step(by offset: Int) {
        let next = currentIndex + offset
        guard sortedPhotos.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentIndex = next
        }
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
            .simultaneousGesture(panGesture)
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
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
        isZoomed = false
    }
}