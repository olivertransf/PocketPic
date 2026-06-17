//
//  GalleryView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct GalleryView: View {
    @EnvironmentObject var photoStore: PhotoStore
    #if canImport(UIKit)
    @Environment(\.requestCamera) private var requestCamera
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @StateObject private var exportViewModel = ExportViewModel()
    @State private var isSelectionMode = false
    @State private var selectedPhotos: Set<Photo.ID> = []
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var pendingExportCompletion = false
    @State private var showEyeDetectionPhoto: Photo?
    @State private var viewerPhotoID: Photo.ID?
    @State private var deleteTargetPhoto: Photo?
    @State private var showSingleDeleteConfirmation = false

    private var collageRowHeight: CGFloat {
        #if canImport(UIKit)
        horizontalSizeClass == .regular ? 168 : 132
        #else
        168
        #endif
    }

    #if canImport(UIKit)
    private var galleryNavigationTitle: String {
        isSelectionMode ? "\(selectedPhotos.count) Selected" : "Library"
    }
    #endif
    
    var sortedPhotos: [Photo] {
        photoStore.photos.sorted { $0.date > $1.date }
    }

    private var currentStreak: Int {
        let calendar = Calendar.current
        let photoDays = Set(photoStore.photos.map { calendar.startOfDay(for: $0.date) })
        guard !photoDays.isEmpty else { return 0 }
        var streak = 0
        var day = calendar.startOfDay(for: Date())
        if !photoDays.contains(day) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        while photoDays.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    private var longestStreak: Int {
        let calendar = Calendar.current
        let unique = Array(Set(photoStore.photos.map { calendar.startOfDay(for: $0.date) })).sorted()
        guard !unique.isEmpty else { return 0 }
        var longest = 1, current = 1
        for i in 1..<unique.count {
            if calendar.date(byAdding: .day, value: 1, to: unique[i - 1]) == unique[i] {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    private var photosByMonth: [(String, [Photo])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        var result: [(String, [Photo])] = []
        var indexMap: [String: Int] = [:]
        for photo in sortedPhotos {
            let key = formatter.string(from: photo.date)
            if let idx = indexMap[key] {
                result[idx].1.append(photo)
            } else {
                indexMap[key] = result.count
                result.append((key, [photo]))
            }
        }
        return result
    }
    
    var body: some View {
        NavigationStack {
            galleryMainContent
                .background {
                    #if os(macOS)
                    Color(nsColor: .windowBackgroundColor)
                    #else
                    Color.systemGroupedBackground
                    #endif
                }
                .navigationTitle(galleryTitle)
                .pocketPicNavigationSubtitle(gallerySubtitle)
                #if canImport(UIKit)
                .navigationBarTitleDisplayMode(isSelectionMode ? .inline : .large)
                .toolbarBackground(.automatic, for: .navigationBar)
                #endif
                .toolbar { galleryToolbar }
                .modifier(GalleryOverlaysModifier(
                    showDeleteConfirmation: $showDeleteConfirmation,
                    showExportSheet: $showExportSheet,
                    pendingExportCompletion: $pendingExportCompletion,
                    showSingleDeleteConfirmation: $showSingleDeleteConfirmation,
                    showEyeDetectionPhoto: $showEyeDetectionPhoto,
                    viewerPhotoID: $viewerPhotoID,
                    deleteTargetPhoto: $deleteTargetPhoto,
                    exportViewModel: exportViewModel,
                    photoStore: photoStore,
                    selectedPhotoCount: selectedPhotos.count,
                    onDeleteSelected: deleteSelectedPhotos
                ))
        }
    }

    private var galleryTitle: String {
        #if canImport(UIKit)
        galleryNavigationTitle
        #else
        isSelectionMode ? "\(selectedPhotos.count) Selected" : "Library"
        #endif
    }

    private var gallerySubtitle: String {
        if isSelectionMode {
            return "Choose photos to delete"
        }
        var parts = ["\(sortedPhotos.count) photos"]
        if currentStreak > 0 {
            parts.append("\(currentStreak)-day streak")
        }
        if longestStreak > currentStreak {
            parts.append("best \(longestStreak)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var galleryMainContent: some View {
        if photoStore.photos.isEmpty {
            galleryEmptyState
        } else {
            galleryPhotoScrollView
        }
    }

    @ViewBuilder
    private var galleryEmptyState: some View {
        #if canImport(UIKit)
        ContentUnavailableView {
            Label("No Photos Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Take your first photo to start your time-lapse.")
        } actions: {
            Button("Open Camera", systemImage: "camera.fill") {
                requestCamera.wrappedValue = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ContentUnavailableView(
            "No Photos Yet",
            systemImage: "photo.on.rectangle.angled",
            description: Text("Take your first photo to start your time-lapse.")
        )
        #endif
    }

    private var galleryPhotoScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                #if canImport(UIKit)
                if #unavailable(iOS 26.0) {
                    Text(gallerySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PocketPicDesign.libraryHeaderInset)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
                #endif

                ForEach(Array(photosByMonth.enumerated()), id: \.offset) { index, group in
                    GalleryMonthSection(
                        monthKey: group.0,
                        monthPhotos: group.1,
                        targetRowHeight: collageRowHeight,
                        isFirstSection: index == 0,
                        isSelectionMode: isSelectionMode,
                        selectedPhotoIDs: selectedPhotos,
                        onTap: handlePhotoTap,
                        onLongPress: handlePhotoLongPress,
                        onViewPhoto: { viewerPhotoID = $0.id },
                        onDetectEyes: { showEyeDetectionPhoto = $0 },
                        onDelete: { photo in
                            deleteTargetPhoto = photo
                            showSingleDeleteConfirmation = true
                        }
                    )
                }
            }
            .pocketPicReadableWidth()
        }
        #if canImport(UIKit)
        .scrollContentBackground(.hidden)
        #endif
    }

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        if isSelectionMode {
            #if canImport(UIKit)
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    withAnimation(.spring()) {
                        exitSelectionMode()
                    }
                }
            }
            #elseif os(macOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    withAnimation(.spring()) {
                        exitSelectionMode()
                    }
                }
            }
            #endif

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring()) {
                        if selectedPhotos.count == sortedPhotos.count {
                            selectedPhotos.removeAll()
                        } else {
                            selectedPhotos = Set(sortedPhotos.map { $0.id })
                        }
                    }
                } label: {
                    Text(selectedPhotos.count == sortedPhotos.count ? "Deselect All" : "Select All")
                }
            }

            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedPhotos.isEmpty)
            }
        } else {
            #if canImport(UIKit)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(photoStore.photos.isEmpty)

                Button {
                    withAnimation(.spring()) {
                        isSelectionMode = true
                    }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                galleryOptionsMenu
            }
            #elseif os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(photoStore.photos.isEmpty)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring()) {
                        isSelectionMode = true
                    }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
            }

            ToolbarItem(placement: .automatic) {
                galleryOptionsMenu
            }
            #endif
        }
    }

    private var galleryOptionsMenu: some View {
        Menu {
            Toggle(
                "Hide Photos",
                isOn: Binding(
                    get: { photoStore.hidePhotosInGallery },
                    set: { photoStore.setHidePhotosInGallery($0) }
                )
            )

            Button {
                photoStore.refreshPhotos()
            } label: {
                Label("Refresh Library", systemImage: "arrow.clockwise")
            }
            .disabled(photoStore.isLoadingPhotoList)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
    
    private func toggleSelection(photo: Photo) {
        if selectedPhotos.contains(photo.id) {
            selectedPhotos.remove(photo.id)
        } else {
            selectedPhotos.insert(photo.id)
        }
    }

    private func handlePhotoTap(_ photo: Photo) {
        if isSelectionMode {
            withAnimation(.spring(response: 0.3)) {
                toggleSelection(photo: photo)
            }
        } else {
            viewerPhotoID = photo.id
        }
    }

    private func handlePhotoLongPress(_ photo: Photo) {
        guard !isSelectionMode else { return }
        deleteTargetPhoto = photo
        showSingleDeleteConfirmation = true
    }
    
    private func exitSelectionMode() {
        withAnimation {
            isSelectionMode = false
            selectedPhotos.removeAll()
        }
    }
    
    private func deleteSelectedPhotos() {
        withAnimation {
            for photoId in selectedPhotos {
                if let photo = photoStore.photos.first(where: { $0.id == photoId }) {
                    photoStore.deletePhoto(photo)
                }
            }
            exitSelectionMode()
        }
    }
}

private enum GalleryCollageLayoutEngine {
    struct Tile: Identifiable {
        let id: Photo.ID
        let photo: Photo
        let width: CGFloat
        let height: CGFloat
    }

    struct Row: Identifiable {
        let id: Int
        let tiles: [Tile]
        let height: CGFloat
    }

    static func rows(
        photos: [Photo],
        aspectRatios: [Photo.ID: CGFloat],
        containerWidth: CGFloat,
        spacing: CGFloat = 1,
        targetRowHeight: CGFloat = 150,
        minRowHeight: CGFloat = 72
    ) -> [Row] {
        guard containerWidth > 0, !photos.isEmpty else { return [] }

        var result: [Row] = []
        var index = 0
        var rowID = 0

        while index < photos.count {
            var rowPhotos: [Photo] = []

            while index < photos.count {
                let candidate = photos[index]
                let testPhotos = rowPhotos + [candidate]
                let aspectSum = testPhotos.reduce(CGFloat.zero) { partial, photo in
                    partial + normalizedAspect(aspectRatios[photo.id])
                }
                let gapTotal = spacing * CGFloat(max(testPhotos.count - 1, 0))
                let rowHeight = (containerWidth - gapTotal) / aspectSum

                if testPhotos.count > 1, rowHeight < minRowHeight {
                    break
                }

                rowPhotos.append(candidate)
                index += 1

                if rowHeight <= targetRowHeight {
                    break
                }
            }

            guard !rowPhotos.isEmpty else { break }

            let isLastRow = index >= photos.count
            let aspectSum = rowPhotos.reduce(CGFloat.zero) { partial, photo in
                partial + normalizedAspect(aspectRatios[photo.id])
            }
            let gapTotal = spacing * CGFloat(max(rowPhotos.count - 1, 0))
            var rowHeight = (containerWidth - gapTotal) / aspectSum

            if isLastRow, rowPhotos.count < 4 {
                rowHeight = min(rowHeight, targetRowHeight)
            }

            let tiles = rowPhotos.map { photo in
                let aspect = normalizedAspect(aspectRatios[photo.id])
                return Tile(
                    id: photo.id,
                    photo: photo,
                    width: rowHeight * aspect,
                    height: rowHeight
                )
            }

            result.append(Row(id: rowID, tiles: tiles, height: rowHeight))
            rowID += 1
        }

        return result
    }

    private static func normalizedAspect(_ ratio: CGFloat?) -> CGFloat {
        guard let ratio, ratio.isFinite, ratio > 0 else { return 1 }
        return min(max(ratio, 0.45), 2.2)
    }
}

private struct GalleryMonthSection: View {
    let monthKey: String
    let monthPhotos: [Photo]
    let targetRowHeight: CGFloat
    var isFirstSection: Bool = false
    let isSelectionMode: Bool
    let selectedPhotoIDs: Set<Photo.ID>
    let onTap: (Photo) -> Void
    let onLongPress: (Photo) -> Void
    let onViewPhoto: (Photo) -> Void
    let onDetectEyes: (Photo) -> Void
    let onDelete: (Photo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(monthKey)
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PocketPicDesign.libraryHeaderInset)
                .padding(.top, isFirstSection ? 4 : 20)
                .padding(.bottom, 6)

            GalleryCollageView(
                photos: monthPhotos,
                spacing: PocketPicDesign.gridSpacing,
                targetRowHeight: targetRowHeight,
                isSelectionMode: isSelectionMode,
                selectedPhotoIDs: selectedPhotoIDs,
                onTap: onTap,
                onLongPress: onLongPress,
                onViewPhoto: onViewPhoto,
                onDetectEyes: onDetectEyes,
                onDelete: onDelete
            )
        }
    }
}

private struct GalleryCollageView: View {
    let photos: [Photo]
    let spacing: CGFloat
    let targetRowHeight: CGFloat
    let isSelectionMode: Bool
    let selectedPhotoIDs: Set<Photo.ID>
    let onTap: (Photo) -> Void
    let onLongPress: (Photo) -> Void
    let onViewPhoto: (Photo) -> Void
    let onDetectEyes: (Photo) -> Void
    let onDelete: (Photo) -> Void

    @EnvironmentObject private var photoStore: PhotoStore
    @State private var aspectRatios: [Photo.ID: CGFloat] = [:]
    #if canImport(UIKit)
    @State private var containerWidth: CGFloat = UIScreen.main.bounds.width
    #else
    @State private var containerWidth: CGFloat = 720
    #endif

    var body: some View {
        collageGrid
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, width in
                if width > 0, abs(width - containerWidth) > 0.5 {
                    containerWidth = width
                }
            }
            .task(id: photos.map(\.id)) {
                await loadAspectRatios()
            }
    }

    @ViewBuilder
    private var collageGrid: some View {
        let layoutWidth = max(containerWidth, 1)
        let rows = GalleryCollageLayoutEngine.rows(
            photos: photos,
            aspectRatios: aspectRatios,
            containerWidth: layoutWidth,
            spacing: spacing,
            targetRowHeight: targetRowHeight
        )

        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(rows) { row in
                HStack(spacing: spacing) {
                    ForEach(row.tiles) { tile in
                        GalleryGridPhotoCell(
                            photo: tile.photo,
                            tileWidth: tile.width,
                            tileHeight: tile.height,
                            isSelected: selectedPhotoIDs.contains(tile.photo.id),
                            isSelectionMode: isSelectionMode,
                            onTap: { onTap(tile.photo) },
                            onLongPress: { onLongPress(tile.photo) },
                            onViewPhoto: { onViewPhoto(tile.photo) },
                            onDetectEyes: { onDetectEyes(tile.photo) },
                            onDelete: { onDelete(tile.photo) }
                        )
                    }
                }
                .frame(width: layoutWidth, height: row.height, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: aspectRatios)
    }

    private func loadAspectRatios() async {
        var loaded: [Photo.ID: CGFloat] = [:]
        await withTaskGroup(of: (Photo.ID, CGFloat).self) { group in
            for photo in photos {
                group.addTask {
                    let ratio = await photoStore.aspectRatio(for: photo)
                    return (photo.id, ratio)
                }
            }
            for await pair in group {
                loaded[pair.0] = pair.1
            }
        }
        aspectRatios = loaded
    }
}

private struct GalleryGridPhotoCell: View {
    @EnvironmentObject var photoStore: PhotoStore
    let photo: Photo
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let isSelected: Bool
    let isSelectionMode: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onViewPhoto: () -> Void
    let onDetectEyes: () -> Void
    let onDelete: () -> Void
    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        Button(action: onTap) {
            PhotoThumbnailCard(
                photo: photo,
                tileWidth: tileWidth,
                tileHeight: tileHeight,
                isSelected: isSelected,
                isSelectionMode: isSelectionMode
            )
        }
        .buttonStyle(.plain)
        .frame(width: tileWidth, height: tileHeight)
        .clipped()
        .contentShape(Rectangle())
        #if os(macOS)
        .opacity(isSelectionMode || !isHovered ? 1 : 0.88)
        .onHover { isHovered = $0 }
        #endif
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in onLongPress() }
        )
        .contextMenu {
            if !isSelectionMode {
                Button(action: onViewPhoto) {
                    Label("View Photo", systemImage: "photo")
                }
                Button(action: onDetectEyes) {
                    Label("Detect Eye Positions", systemImage: "eye")
                }
                .disabled(!photoStore.canLoadImage(for: photo))
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct PhotoThumbnailCard: View {
    @EnvironmentObject var photoStore: PhotoStore
    @Environment(\.displayScale) private var displayScale
    let photo: Photo
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let isSelected: Bool
    let isSelectionMode: Bool

    @State private var thumbnail: PlatformImage?

    var body: some View {
        let loadSize = max(tileWidth, tileHeight)
        ZStack {
            if photoStore.hidePhotosInGallery {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            } else if let image = thumbnail {
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: tileWidth, height: tileHeight)
                    .clipped()
                #elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: tileWidth, height: tileHeight)
                    .clipped()
                #endif
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(ProgressView().controlSize(.small))
            }

            // Selection overlay — Photos-style checkmark badge
            if isSelectionMode {
                Color.black.opacity(isSelected ? 0 : 0.28)

                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .strokeBorder(Color.white.opacity(isSelected ? 0 : 0.9), lineWidth: 1.5)
                                .background(Circle().fill(isSelected ? Color.accentColor : Color.black.opacity(0.22)))
                                .frame(width: 22, height: 22)
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(6)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: tileWidth, height: tileHeight)
        .clipped()
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .onChange(of: photoStore.hidePhotosInGallery) { _, hidden in
            if hidden { thumbnail = nil }
        }
        .task(id: "\(photo.id.uuidString)-\(Int(loadSize * 100))-\(photoStore.hidePhotosInGallery)") {
            guard !photoStore.hidePhotosInGallery, loadSize > 1 else { return }
            let loaded = await photoStore.loadThumbnail(for: photo, pointWidth: loadSize, displayScale: displayScale)
            guard !Task.isCancelled, !photoStore.hidePhotosInGallery else { return }
            if let loaded {
                withAnimation(.easeIn(duration: 0.12)) {
                    thumbnail = loaded
                }
            }
        }
        .onDisappear {
            photoStore.cancelThumbnailRequest(for: photo)
        }
    }
}

// Export Sheet View for Gallery
struct ExportSheetView: View {
    @EnvironmentObject var photoStore: PhotoStore
    @ObservedObject var exportViewModel: ExportViewModel
    @Binding var showExportSheet: Bool
    
    private var videoDuration: Double {
        Double(photoStore.photos.count) / Double(exportViewModel.selectedFPS)
    }
    
    private var estimatedFileSize: String {
        // Rough estimate: 6 Mbps bitrate, duration in seconds
        let bitrateMbps: Double = 6.0
        let sizeMB = (bitrateMbps * videoDuration) / 8.0
        return String(format: "~%.1f MB", sizeMB)
    }
    
    
    private var summaryRow: some View {
        PocketPicModalHeader(
            "\(photoStore.photos.count) \(photoStore.photos.count == 1 ? "photo" : "photos")",
            subtitle: "\(String(format: "%.1f", videoDuration))s · \(estimatedFileSize)",
            systemImage: "film.stack"
        )
    }

    private var exportButton: some View {
        Button {
            Task {
                await exportViewModel.exportVideo(photos: photoStore.photos, photoStore: photoStore)
            }
        } label: {
            Text("Export Montage")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(exportViewModel.isExporting)
        #if canImport(UIKit)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        #endif
    }

    var body: some View {
        Group {
            if photoStore.photos.isEmpty {
                ContentUnavailableView(
                    "No Photos to Export",
                    systemImage: "film.stack",
                    description: Text("Take some photos first to create your montage.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                #if os(macOS)
                macOSExportForm
                #else
                iOSExportForm
                #endif
            }
        }
        .navigationTitle("Export Montage")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .interactiveDismissDisabled(exportViewModel.isExporting)
        .toolbar { exportToolbar }
        .overlay {
            if exportViewModel.isExporting {
                exportingOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
    }

    #if os(macOS)
    private var macOSExportForm: some View {
        Form {
            Section {
                LabeledContent("Photos") {
                    Text("\(photoStore.photos.count)")
                        .monospacedDigit()
                }
                LabeledContent("Duration") {
                    Text(String(format: "%.1f s", videoDuration))
                        .monospacedDigit()
                }
                LabeledContent("Estimated size") {
                    Text(estimatedFileSize)
                }
            }

            Section {
                Picker("Frame Rate", selection: $exportViewModel.selectedFPS) {
                    ForEach(exportViewModel.availableFPSOptions, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(photoStore.useNativeResolution ? "Native resolution · HEVC" : "Auto orientation · H.264 · 1080p")
            }

            Section {
                Toggle(isOn: $exportViewModel.alignEyes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Align Eyes")
                        Text("Matches position, rotation, and eye size to the first photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.appAccent)
            }
        }
        .formStyle(.grouped)
    }
    #endif

    #if canImport(UIKit)
    private var iOSExportForm: some View {
        Form {
            Section {
                summaryRow
            }

            Section {
                Picker("Frame Rate", selection: $exportViewModel.selectedFPS) {
                    ForEach(exportViewModel.availableFPSOptions, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(photoStore.useNativeResolution ? "Native resolution · HEVC" : "Auto orientation · H.264 · 1080p")
            }

            Section {
                Toggle(isOn: $exportViewModel.alignEyes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Align Eyes")
                        Text("Matches position, rotation, and eye size to the first photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.appAccent)
            } header: {
                Text("Options")
            }
        }
        .safeAreaInset(edge: .bottom) {
            exportButton
        }
    }
    #endif

    @ToolbarContentBuilder
    private var exportToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                showExportSheet = false
            }
            .disabled(exportViewModel.isExporting)
        }

        #if os(macOS)
        ToolbarItem(placement: .confirmationAction) {
            Button("Export") {
                Task {
                    await exportViewModel.exportVideo(photos: photoStore.photos, photoStore: photoStore)
                }
            }
            .disabled(exportViewModel.isExporting || photoStore.photos.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        #endif
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: exportViewModel.exportProgress) {
                    Text("Creating Montage")
                        .font(.headline)
                } currentValueLabel: {
                    Text("\(Int(exportViewModel.exportProgress * 100))%")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .progressViewStyle(.circular)
                .controlSize(.large)

                Text(exportViewModel.exportStatus.isEmpty ? "Starting export…" : exportViewModel.exportStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 20)
            }
            .padding(28)
            .frame(maxWidth: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct ExportCompleteSheet: View {
    let videoURL: URL
    let previewImage: PlatformImage?
    @ObservedObject var exportViewModel: ExportViewModel
    let onDismiss: () -> Void

    @State private var showShareSheet = false
    @State private var isPreparingShare = false
    @State private var isSavingToPhotos = false
    @State private var didSaveToPhotos = false

    var body: some View {
        #if os(macOS)
        macOSExportCompleteBody
        #else
        iOSExportCompleteBody
        #endif
    }

    #if os(macOS)
    private var macOSExportCompleteBody: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    exportPreview
                    Label("Montage Ready", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("Your time-lapse video has been created.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Button {
                    Task {
                        isSavingToPhotos = true
                        exportViewModel.errorMessage = nil
                        await exportViewModel.saveToPhotos(videoURL: videoURL)
                        isSavingToPhotos = false
                        if exportViewModel.errorMessage == nil {
                            didSaveToPhotos = true
                        }
                    }
                } label: {
                    Label {
                        if isSavingToPhotos {
                            Text("Saving…")
                        } else if didSaveToPhotos {
                            Text("Saved to Photos")
                        } else {
                            Text("Save to Photos")
                        }
                    } icon: {
                        if isSavingToPhotos {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: didSaveToPhotos ? "checkmark.circle.fill" : "photo.on.rectangle.angled")
                        }
                    }
                }
                .disabled(isSavingToPhotos)

                Button {
                    presentMacSharePicker()
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .disabled(isSavingToPhotos)

                Button {
                    SaveToFileHelper.showSavePanel(
                        sourceURL: videoURL,
                        onSuccess: { exportViewModel.completedExport = nil },
                        onError: { exportViewModel.errorMessage = $0 }
                    )
                } label: {
                    Label("Save to File…", systemImage: "folder")
                }
                .disabled(isSavingToPhotos)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Export Complete")
        .alert("Error", isPresented: .constant(exportViewModel.errorMessage != nil)) {
            Button("OK") {
                exportViewModel.errorMessage = nil
            }
        } message: {
            if let error = exportViewModel.errorMessage {
                Text(error)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSavingToPhotos)
            }
        }
    }
    #endif

    #if canImport(UIKit)
    private var iOSExportCompleteBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                exportPreview

                VStack(spacing: 6) {
                    Label("Montage Ready", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("Your time-lapse video has been created.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                        Button {
                            Task {
                                isSavingToPhotos = true
                                exportViewModel.errorMessage = nil
                                await exportViewModel.saveToPhotos(videoURL: videoURL)
                                isSavingToPhotos = false
                                if exportViewModel.errorMessage == nil {
                                    didSaveToPhotos = true
                                }
                            }
                        } label: {
                            Group {
                                if isSavingToPhotos {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if didSaveToPhotos {
                                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                                } else {
                                    Label("Save to Photos", systemImage: "photo.on.rectangle.angled")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isSavingToPhotos || isPreparingShare)

                        Button {
                            isPreparingShare = true
                            DispatchQueue.main.async {
                                showShareSheet = true
                            }
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isSavingToPhotos || isPreparingShare)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.systemGroupedBackground)
        .navigationTitle("Export Complete")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: .constant(exportViewModel.errorMessage != nil)) {
            Button("OK") {
                exportViewModel.errorMessage = nil
            }
        } message: {
            if let error = exportViewModel.errorMessage {
                Text(error)
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            isPreparingShare = false
        }) {
            ShareSheet(items: [videoURL])
                .onAppear {
                    isPreparingShare = false
                }
        }
        .overlay {
            if isPreparingShare {
                sharePreparingOverlay
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { onDismiss() }
                    .fontWeight(.medium)
                    .disabled(isSavingToPhotos || isPreparingShare)
            }
        }
    }
    #endif

    @ViewBuilder
    private var exportPreview: some View {
        Group {
            if let previewImage {
                #if canImport(UIKit)
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                #elseif canImport(AppKit)
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
                #endif
            } else {
                Color.secondary.opacity(0.12)
                    .overlay {
                        Image(systemName: "film")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    #if os(macOS)
    private func presentMacSharePicker() {
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            exportViewModel.errorMessage = "Exported video file is no longer available"
            return
        }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [videoURL as NSURL])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }
    #endif

    private var sharePreparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView()
                    .scaleEffect(1.35)
                    .tint(.white)
                Text("Opening share…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Hang on while we prepare the share sheet.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .frame(maxWidth: 280)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .allowsHitTesting(true)
    }
}

#if os(macOS)
private enum SaveToFileHelper {
    static func showSavePanel(sourceURL: URL, onSuccess: @escaping () -> Void, onError: @escaping (String) -> Void) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "PocketPic_Montage.mp4"
        savePanel.canCreateDirectories = true
        savePanel.title = "Save Video"
        savePanel.message = "Choose where to save your montage video"
        savePanel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        savePanel.begin { response in
            guard response == .OK, let destURL = savePanel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                DispatchQueue.main.async(execute: onSuccess)
            } catch {
                DispatchQueue.main.async { onError("Failed to save: \(error.localizedDescription)") }
            }
        }
    }
}

private struct SharePickerAnchorView: NSViewRepresentable {
    let items: [Any]
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard !items.isEmpty, !context.coordinator.hasShown,
              let url = items.compactMap({ $0 as? URL }).first else { return }
        context.coordinator.hasShown = true
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onDismiss() }
        }
    }

    class Coordinator { var hasShown = false }
}
#endif

// Share Sheet for iOS/macOS
#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed
    }
}
#elseif canImport(AppKit)
struct ShareSheet: NSViewRepresentable {
    let items: [Any]
    
    func makeNSView(context: Context) -> ShareSheetHostView {
        let view = ShareSheetHostView()
        view.items = items
        return view
    }
    
    func updateNSView(_ nsView: ShareSheetHostView, context: Context) {
        nsView.items = items
    }
}

class ShareSheetHostView: NSView {
    var items: [Any] = [] {
        didSet { showSharePickerIfNeeded() }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in self?.showSharePickerIfNeeded() }
        }
    }
    
    private var hasShown = false
    private func showSharePickerIfNeeded() {
        guard !hasShown, !items.isEmpty, let url = items.compactMap({ $0 as? URL }).first else { return }
        hasShown = true
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
}
#endif

struct EyeDetectionSheet: View {
    let photo: Photo
    @ObservedObject var photoStore: PhotoStore
    @Environment(\.dismiss) private var dismiss
    @State private var eyeLocations: EyeLocations?
    @State private var errorMessage: String?
    @State private var isDetecting = false
    @State private var loadedImage: PlatformImage?
    @State private var loadFailed = false
    
    var body: some View {
        NavigationStack {
            Group {
                if let image = loadedImage {
                    EyeDetectionContentView(
                        image: image,
                        eyeLocations: eyeLocations
                    )
                } else if loadFailed {
                    ContentUnavailableView("Could not load photo", systemImage: "photo")
                } else {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.systemGroupedBackground)
            .navigationTitle("Eye Detection")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        runDetection(image: loadedImage)
                    } label: {
                        if isDetecting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("Detect Eyes")
                        }
                    }
                    .disabled(isDetecting || loadedImage == nil)
                }
            }
            .task {
                loadedImage = await photoStore.loadImageAsync(for: photo)
                loadFailed = loadedImage == nil
                if loadedImage != nil {
                    runDetection(image: loadedImage)
                }
            }
            .alert("Detection Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
        }
        .pocketPicModalPresentation(.eyeDetection)
    }
    
    private func runDetection(image: PlatformImage?) {
        guard let image = image else { return }
        isDetecting = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try EyeDetectionService.detectEyes(in: image)
                await MainActor.run {
                    eyeLocations = result
                    isDetecting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDetecting = false
                }
            }
        }
    }
}

struct EyeDetectionContentView: View {
    let image: PlatformImage
    let eyeLocations: EyeLocations?
    
    var body: some View {
        GeometryReader { geometry in
            let imageSize = eyeLocations?.imageSize ?? CGSize(
                width: CGFloat(image.size.width),
                height: CGFloat(image.size.height)
            )
            let scale = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
            let scaledWidth = imageSize.width * scale
            let scaledHeight = imageSize.height * scale

            ZStack {
                Color.black.opacity(0.04)
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: scaledWidth, height: scaledHeight)
                    .overlay { eyeOverlay(imageSize: imageSize, scale: scale) }
                #elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: scaledWidth, height: scaledHeight)
                    .overlay { eyeOverlay(imageSize: imageSize, scale: scale) }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func eyeOverlay(imageSize: CGSize, scale: CGFloat) -> some View {
        if let locations = eyeLocations {
            let leftX = locations.leftEye.x * scale
            let leftY = locations.leftEye.y * scale
            let rightX = locations.rightEye.x * scale
            let rightY = locations.rightEye.y * scale
            
            Circle()
                .stroke(Color.green, lineWidth: 3)
                .frame(width: 24, height: 24)
                .position(x: leftX, y: leftY)
            Circle()
                .stroke(Color.green, lineWidth: 3)
                .frame(width: 24, height: 24)
                .position(x: rightX, y: rightY)
        }
    }
}

private struct GalleryOverlaysModifier: ViewModifier {
    @Binding var showDeleteConfirmation: Bool
    @Binding var showExportSheet: Bool
    @Binding var pendingExportCompletion: Bool
    @Binding var showSingleDeleteConfirmation: Bool
    @Binding var showEyeDetectionPhoto: Photo?
    @Binding var viewerPhotoID: Photo.ID?
    @Binding var deleteTargetPhoto: Photo?
    @ObservedObject var exportViewModel: ExportViewModel
    let photoStore: PhotoStore
    let selectedPhotoCount: Int
    let onDeleteSelected: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Delete Photos", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete \(selectedPhotoCount) Photo\(selectedPhotoCount == 1 ? "" : "s")", role: .destructive) {
                    onDeleteSelected()
                }
            } message: {
                Text("Are you sure you want to delete \(selectedPhotoCount) photo\(selectedPhotoCount == 1 ? "" : "s")? This action cannot be undone.")
            }
            .sheet(isPresented: $showExportSheet) {
                NavigationStack {
                    ExportSheetView(exportViewModel: exportViewModel, showExportSheet: $showExportSheet)
                        .environmentObject(photoStore)
                }
                #if canImport(UIKit)
                .presentationDetents([.large])
                .pocketPicSheetChrome()
                #else
                .pocketPicModalPresentation(.export)
                #endif
            }
            .onChange(of: exportViewModel.isExporting) { wasExporting, isExporting in
                guard wasExporting, !isExporting, exportViewModel.exportedVideoURL != nil else { return }
                pendingExportCompletion = true
                showExportSheet = false
            }
            .onChange(of: showExportSheet) { _, isShowing in
                guard !isShowing, pendingExportCompletion else { return }
                pendingExportCompletion = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    presentExportCompletionIfNeeded(exportSheetVisible: false)
                }
            }
            .alert("Error", isPresented: .constant(exportViewModel.errorMessage != nil)) {
                Button("OK") {
                    exportViewModel.errorMessage = nil
                }
            } message: {
                if let error = exportViewModel.errorMessage {
                    Text(error)
                }
            }
            .sheet(item: Binding(
                get: { exportViewModel.completedExport },
                set: { exportViewModel.completedExport = $0 }
            )) { completion in
                NavigationStack {
                    ExportCompleteSheet(
                        videoURL: completion.videoURL,
                        previewImage: exportViewModel.exportPreviewImage,
                        exportViewModel: exportViewModel,
                        onDismiss: {
                            exportViewModel.completedExport = nil
                            exportViewModel.exportedVideoURL = nil
                            exportViewModel.exportPreviewImage = nil
                        }
                    )
                }
                #if canImport(UIKit)
                .presentationDetents([.large])
                .pocketPicSheetChrome()
                #else
                .pocketPicModalPresentation(.exportComplete)
                #endif
            }
            .modifier(PhotoViewerPresentation(photoID: $viewerPhotoID))
            #if os(macOS)
            .sheet(item: $showEyeDetectionPhoto) { photo in
                EyeDetectionSheet(photo: photo, photoStore: photoStore)
            }
            #else
            .fullScreenCover(item: $showEyeDetectionPhoto) { photo in
                EyeDetectionSheet(photo: photo, photoStore: photoStore)
            }
            #endif
            .confirmationDialog(
                "Delete Photo",
                isPresented: $showSingleDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let photo = deleteTargetPhoto {
                        photoStore.deletePhoto(photo)
                        deleteTargetPhoto = nil
                    }
                }
            } message: {
                Text("This will permanently remove the photo from your library.")
            }
    }

    private func presentExportCompletionIfNeeded(exportSheetVisible: Bool) {
        guard !exportSheetVisible,
              let url = exportViewModel.exportedVideoURL,
              !exportViewModel.isExporting,
              exportViewModel.completedExport == nil else { return }
        exportViewModel.completedExport = ExportCompletion(videoURL: url)
    }
}

private struct PhotoViewerPresentation: ViewModifier {
    @Binding var photoID: Photo.ID?
    @EnvironmentObject private var photoStore: PhotoStore
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var viewer: some View {
        PhotoViewerView(
            photos: photoStore.photos,
            selectedPhotoID: $photoID
        )
        .environmentObject(photoStore)
    }

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .sheet(isPresented: viewerPresented) {
                viewer
                    .frame(minWidth: 760, minHeight: 620)
            }
            #elseif canImport(UIKit)
            .modifier(IOSPhotoViewerPresentation(
                isPresented: viewerPresented,
                useSheet: horizontalSizeClass == .regular
            ) {
                viewer
            })
            #endif
    }

    private var viewerPresented: Binding<Bool> {
        Binding(
            get: { photoID != nil },
            set: { isPresented in
                if !isPresented { photoID = nil }
            }
        )
    }
}

#if canImport(UIKit) && !os(macOS)
private struct IOSPhotoViewerPresentation<Viewer: View>: ViewModifier {
    @Binding var isPresented: Bool
    let useSheet: Bool
    @ViewBuilder let viewer: () -> Viewer

    func body(content: Content) -> some View {
        if useSheet {
            content
                .sheet(isPresented: $isPresented) {
                    viewer()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        } else {
            content
                .fullScreenCover(isPresented: $isPresented) {
                    viewer()
                }
        }
    }
}
#endif

#Preview {
    GalleryView()
        .environmentObject(PhotoStore())
}
