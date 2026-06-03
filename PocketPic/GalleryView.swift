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

enum SortOption: String, CaseIterable {
    case newestFirst = "Newest First"
    case oldestFirst = "Oldest First"
    case fileName = "File Name"
}

struct GalleryView: View {
    @EnvironmentObject var photoStore: PhotoStore
    #if canImport(UIKit)
    @Environment(\.requestCamera) private var requestCamera
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @StateObject private var exportViewModel = ExportViewModel()
    @State private var sortOption: SortOption = .newestFirst
    @State private var isSelectionMode = false
    @State private var selectedPhotos: Set<Photo.ID> = []
    @State private var showDeleteConfirmation = false
    @State private var showExportSheet = false
    @State private var pendingShareSheet = false
    @State private var showEyeDetectionPhoto: Photo?
    @State private var detailPhoto: Photo?
    @State private var deleteTargetPhoto: Photo?
    @State private var showSingleDeleteConfirmation = false
    
    private var galleryColumns: [GridItem] {
        #if canImport(UIKit)
        let minimum: CGFloat = horizontalSizeClass == .regular ? 132 : 96
        let maximum: CGFloat = horizontalSizeClass == .regular ? 200 : 148
        #else
        let minimum: CGFloat = 110
        let maximum: CGFloat = 180
        #endif
        return [GridItem(.adaptive(minimum: minimum, maximum: maximum), spacing: 2)]
    }

    #if canImport(UIKit)
    private var galleryNavigationTitle: String {
        isSelectionMode ? "\(selectedPhotos.count) Selected" : "Photos"
    }
    #endif
    
    var sortedPhotos: [Photo] {
        switch sortOption {
        case .newestFirst:
            return photoStore.photos.sorted { $0.date > $1.date }
        case .oldestFirst:
            return photoStore.photos.sorted { $0.date < $1.date }
        case .fileName:
            return photoStore.photos.sorted { $0.filename < $1.filename }
        }
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
                .background(Color.systemGroupedBackground)
                .navigationTitle(galleryTitle)
                #if canImport(UIKit)
                .navigationBarTitleDisplayMode(isSelectionMode ? .inline : .large)
                #endif
                .toolbar { galleryToolbar }
                .modifier(GalleryOverlaysModifier(
                    showDeleteConfirmation: $showDeleteConfirmation,
                    showExportSheet: $showExportSheet,
                    showSingleDeleteConfirmation: $showSingleDeleteConfirmation,
                    showEyeDetectionPhoto: $showEyeDetectionPhoto,
                    detailPhoto: $detailPhoto,
                    pendingShareSheet: $pendingShareSheet,
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
        isSelectionMode ? "\(selectedPhotos.count) Selected" : "Gallery"
        #endif
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
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                GalleryStatsBanner(
                    currentStreak: currentStreak,
                    longestStreak: longestStreak,
                    totalPhotos: sortedPhotos.count
                )

                ForEach(Array(photosByMonth.enumerated()), id: \.offset) { _, group in
                    GalleryMonthSection(
                        monthKey: group.0,
                        monthPhotos: group.1,
                        columns: galleryColumns,
                        isSelectionMode: isSelectionMode,
                        selectedPhotoIDs: selectedPhotos,
                        onTap: handlePhotoTap,
                        onLongPress: handlePhotoLongPress,
                        onViewPhoto: { detailPhoto = $0 },
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
    }

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
                #if canImport(UIKit)
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        Button("Cancel") {
                            withAnimation(.spring()) {
                                exitSelectionMode()
                            }
                        }
                    } else {
                        Button {
                            photoStore.setHidePhotosInGallery(!photoStore.hidePhotosInGallery)
                        } label: {
                            Label(
                                photoStore.hidePhotosInGallery ? "Show Photos" : "Hide Photos",
                                systemImage: photoStore.hidePhotosInGallery ? "eye.slash" : "eye"
                            )
                        }
                    }
                }
                #elseif canImport(AppKit)
                ToolbarItem(placement: .navigation) {
                    if isSelectionMode {
                        Button("Cancel") {
                            withAnimation(.spring()) {
                                exitSelectionMode()
                            }
                        }
                    } else {
                        Button(action: {
                            photoStore.refreshPhotos()
                        }) {
                            if photoStore.isLoadingPhotoList {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(photoStore.isLoadingPhotoList)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: Binding(
                        get: { photoStore.hidePhotosInGallery },
                        set: { photoStore.setHidePhotosInGallery($0) }
                    )) {
                        Image(systemName: photoStore.hidePhotosInGallery ? "eye.slash" : "eye")
                    }
                    .help("Hide photos in the gallery")
                }
                #endif
                
                if isSelectionMode {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            withAnimation(.spring()) {
                                if selectedPhotos.count == sortedPhotos.count {
                                    selectedPhotos.removeAll()
                                } else {
                                    selectedPhotos = Set(sortedPhotos.map { $0.id })
                                }
                            }
                        }) {
                            Text(selectedPhotos.count == sortedPhotos.count ? "Deselect All" : "Select All")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive, action: {
                            showDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedPhotos.isEmpty)
                    }
                } else {
                    #if canImport(UIKit)
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showExportSheet = true
                            } label: {
                                Label("Export Montage", systemImage: "square.and.arrow.up")
                            }
                            .disabled(photoStore.photos.isEmpty)

                            Menu("Sort By") {
                                ForEach(SortOption.allCases, id: \.self) { option in
                                    Button {
                                        withAnimation {
                                            sortOption = option
                                        }
                                    } label: {
                                        if sortOption == option {
                                            Label(option.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(option.rawValue)
                                        }
                                    }
                                }
                            }

                            Button {
                                withAnimation(.spring()) {
                                    isSelectionMode = true
                                }
                            } label: {
                                Label("Select Photos", systemImage: "checkmark.circle")
                            }

                            Divider()

                            Button {
                                photoStore.refreshPhotos()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .disabled(photoStore.isLoadingPhotoList)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    #else
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            showExportSheet = true
                        }) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .disabled(photoStore.photos.isEmpty)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Button(action: {
                                    withAnimation {
                                        sortOption = option
                                    }
                                }) {
                                    HStack {
                                        Text(option.rawValue)
                                        if sortOption == option {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .controlSize(.large)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            withAnimation(.spring()) {
                                isSelectionMode = true
                            }
                        }) {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                    #endif
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
            detailPhoto = photo
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

struct GalleryStatsBanner: View {
    let currentStreak: Int
    let longestStreak: Int
    let totalPhotos: Int

    var body: some View {
        HStack(spacing: 0) {
            statColumn(
                value: currentStreak,
                label: "Day streak",
                icon: "flame.fill",
                tint: currentStreak > 0 ? .orange : .secondary
            )
            Divider().padding(.vertical, 8)
            statColumn(
                value: longestStreak,
                label: "Best",
                icon: "trophy.fill",
                tint: .yellow
            )
            Divider().padding(.vertical, 8)
            statColumn(
                value: totalPhotos,
                label: "Photos",
                icon: "photo.stack.fill",
                tint: Color.appAccent
            )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func statColumn(value: Int, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text("\(value)")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GalleryMonthSectionHeader: View {
    let monthKey: String
    let photoCount: Int

    var body: some View {
        HStack {
            Text(monthKey)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(photoCount)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.systemGroupedBackground)
    }
}

private struct GalleryMonthSection: View {
    let monthKey: String
    let monthPhotos: [Photo]
    let columns: [GridItem]
    let isSelectionMode: Bool
    let selectedPhotoIDs: Set<Photo.ID>
    let onTap: (Photo) -> Void
    let onLongPress: (Photo) -> Void
    let onViewPhoto: (Photo) -> Void
    let onDetectEyes: (Photo) -> Void
    let onDelete: (Photo) -> Void

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(monthPhotos) { photo in
                    GalleryGridPhotoCell(
                        photo: photo,
                        isSelected: selectedPhotoIDs.contains(photo.id),
                        isSelectionMode: isSelectionMode,
                        onTap: { onTap(photo) },
                        onLongPress: { onLongPress(photo) },
                        onViewPhoto: { onViewPhoto(photo) },
                        onDetectEyes: { onDetectEyes(photo) },
                        onDelete: { onDelete(photo) }
                    )
                }
            }
        } header: {
            GalleryMonthSectionHeader(monthKey: monthKey, photoCount: monthPhotos.count)
        }
    }
}

private struct GalleryGridPhotoCell: View {
    @EnvironmentObject var photoStore: PhotoStore
    let photo: Photo
    let isSelected: Bool
    let isSelectionMode: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onViewPhoto: () -> Void
    let onDetectEyes: () -> Void
    let onDelete: () -> Void

    var body: some View {
        PhotoThumbnailCard(
            photo: photo,
            isSelected: isSelected,
            isSelectionMode: isSelectionMode
        )
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4, perform: onLongPress)
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
    let isSelected: Bool
    let isSelectionMode: Bool

    @State private var thumbnail: PlatformImage?

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                if photoStore.hidePhotosInGallery {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: side, height: side)
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
                        .frame(width: side, height: side)
                        .clipped()
                    #elseif canImport(AppKit)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                    #endif
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: side, height: side)
                        .overlay(ProgressView().controlSize(.small))
                }

                // Selection overlay
                if isSelectionMode {
                    // Dim unselected
                    Color.black.opacity(isSelected ? 0 : 0.25)

                    VStack {
                        HStack {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Color.appAccent : Color.white.opacity(0.85))
                                    .frame(width: 24, height: 24)
                                    .shadow(color: .black.opacity(0.15), radius: 2)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.system(size: 12, weight: .bold))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(7)
                        }
                        Spacer()
                    }
                }

                // Selected highlight border
                if isSelected && isSelectionMode {
                    Rectangle()
                        .stroke(Color.appAccent, lineWidth: 3)
                }
            }
            .scaleEffect(isSelected && isSelectionMode ? 0.96 : 1.0)
            .onChange(of: photoStore.hidePhotosInGallery) { _, hidden in
                if hidden { thumbnail = nil }
            }
            .task(id: "\(photo.id.uuidString)-\(Int(side * 100))-\(photoStore.hidePhotosInGallery)") {
                guard !photoStore.hidePhotosInGallery, side > 1 else { return }
                let loaded = await photoStore.loadThumbnail(for: photo, pointWidth: side, displayScale: displayScale)
                // Task cancellation (cell scrolled away) — check before applying
                guard !Task.isCancelled, !photoStore.hidePhotosInGallery else { return }
                if let loaded {
                    withAnimation(.easeIn(duration: 0.12)) {
                        thumbnail = loaded
                    }
                }
            }
            .onDisappear {
                // Cancel any in-flight PHImageManager request for this cell
                photoStore.cancelThumbnailRequest(for: photo)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// Export Sheet View for Gallery
struct ExportSheetView: View {
    @EnvironmentObject var photoStore: PhotoStore
    @ObservedObject var exportViewModel: ExportViewModel
    @Binding var showExportSheet: Bool
    @Environment(\.dismiss) private var dismiss
    
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appAccent.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "film.stack")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(photoStore.photos.count) \(photoStore.photos.count == 1 ? "photo" : "photos")")
                    .font(.headline)
                Text("\(String(format: "%.1f", videoDuration))s · \(estimatedFileSize)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationStack {
            Group {
                if photoStore.photos.isEmpty {
                    ContentUnavailableView(
                        "No Photos to Export",
                        systemImage: "film.stack",
                        description: Text("Take some photos first to create your montage.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            summaryRow
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.systemBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            PocketPicSectionCard("Frame Rate", content: {
                                Picker("", selection: $exportViewModel.selectedFPS) {
                                    ForEach(exportViewModel.availableFPSOptions, id: \.self) { fps in
                                        Text("\(fps) fps").tag(fps)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }, footer: {
                                Text(photoStore.useNativeResolution ? "Native resolution · HEVC" : "Auto orientation · H.264 · 1080p")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            })

                            PocketPicSectionCard("Options") {
                                Toggle(isOn: $exportViewModel.alignEyes) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Align Eyes")
                                        Text("Lines up eyes across frames for a smoother montage")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tint(Color.appAccent)
                            }

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
                        }
                        .padding(20)
                    }
                }
            }
            .background(Color.systemGroupedBackground)
            .navigationTitle("Export Montage")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .fontWeight(.medium)
                    .disabled(exportViewModel.isExporting)
                }
            }
            .overlay {
                if exportViewModel.isExporting {
                    exportingOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.25)))
                }
            }
        }
        .pocketPicModalPresentation(.export)
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 8)
                        .frame(width: 110, height: 110)

                    Circle()
                        .trim(from: 0, to: exportViewModel.exportProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 110, height: 110)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.15), value: exportViewModel.exportProgress)

                    Text("\(Int(exportViewModel.exportProgress * 100))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                VStack(spacing: 8) {
                    Text("Creating Montage")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Text(exportViewModel.exportStatus.isEmpty ? "Starting export…" : exportViewModel.exportStatus)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 20)
                }

                ProgressView(value: exportViewModel.exportProgress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 220)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

struct ExportCompleteSheet: View {
    let videoURL: URL
    let previewImage: PlatformImage?
    let albumName: String
    @ObservedObject var exportViewModel: ExportViewModel
    let onDismiss: () -> Void

    @State private var showShareSheet = false
    @State private var isPreparingShare = false
    @State private var isSavingToPhotos = false
    @State private var didSaveToPhotos = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    exportPreview

                    VStack(spacing: 6) {
                        Label("Montage Ready", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.appAccent)
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
                                await exportViewModel.saveToPhotos(videoURL: videoURL, albumName: albumName)
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
                            #if os(macOS)
                            presentMacSharePicker()
                            #else
                            isPreparingShare = true
                            DispatchQueue.main.async {
                                showShareSheet = true
                            }
                            #endif
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isSavingToPhotos || isPreparingShare)

                        #if os(macOS)
                        Button {
                            SaveToFileHelper.showSavePanel(
                                sourceURL: videoURL,
                                onSuccess: { exportViewModel.showShareSheet = false },
                                onError: { exportViewModel.errorMessage = $0 }
                            )
                        } label: {
                            Label("Save to File…", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isSavingToPhotos || isPreparingShare)
                        #endif
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.systemGroupedBackground)
            .navigationTitle("Export Complete")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Error", isPresented: .constant(exportViewModel.errorMessage != nil)) {
                Button("OK") {
                    exportViewModel.errorMessage = nil
                }
            } message: {
                if let error = exportViewModel.errorMessage {
                    Text(error)
                }
            }
            #if !os(macOS)
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
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                        .fontWeight(.medium)
                        .disabled(isSavingToPhotos || isPreparingShare)
                }
            }
        }
        .pocketPicModalPresentation(.exportComplete)
    }

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
    @Binding var showSingleDeleteConfirmation: Bool
    @Binding var showEyeDetectionPhoto: Photo?
    @Binding var detailPhoto: Photo?
    @Binding var pendingShareSheet: Bool
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
                ExportSheetView(exportViewModel: exportViewModel, showExportSheet: $showExportSheet)
                    .environmentObject(photoStore)
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
            .onChange(of: exportViewModel.showShareSheet) { _, newValue in
                if newValue && showExportSheet {
                    pendingShareSheet = true
                    showExportSheet = false
                }
            }
            .onChange(of: showExportSheet) { _, newValue in
                if !newValue && pendingShareSheet {
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await MainActor.run {
                            pendingShareSheet = false
                            exportViewModel.showShareSheet = true
                        }
                    }
                }
            }
            .sheet(isPresented: $exportViewModel.showShareSheet) {
                if let videoURL = exportViewModel.exportedVideoURL {
                    ExportCompleteSheet(
                        videoURL: videoURL,
                        previewImage: exportViewModel.exportPreviewImage,
                        albumName: photoStore.targetAlbum,
                        exportViewModel: exportViewModel,
                        onDismiss: { exportViewModel.showShareSheet = false }
                    )
                }
            }
            #if os(macOS)
            .sheet(item: $showEyeDetectionPhoto) { photo in
                EyeDetectionSheet(photo: photo, photoStore: photoStore)
            }
            .sheet(item: $detailPhoto) { photo in
                PhotoDetailView(photo: photo)
                    .environmentObject(photoStore)
            }
            #else
            .fullScreenCover(item: $showEyeDetectionPhoto) { photo in
                EyeDetectionSheet(photo: photo, photoStore: photoStore)
            }
            .modifier(PhotoDetailPresentation(photo: $detailPhoto))
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
}

#if canImport(UIKit)
private struct PhotoDetailPresentation: ViewModifier {
    @Binding var photo: Photo?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var photoStore: PhotoStore

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .sheet(item: $photo) { photo in
                    PhotoDetailView(photo: photo)
                        .environmentObject(photoStore)
                }
        } else {
            content
                .fullScreenCover(item: $photo) { photo in
                    PhotoDetailView(photo: photo)
                        .environmentObject(photoStore)
                }
        }
    }
}
#endif

#Preview {
    GalleryView()
        .environmentObject(PhotoStore())
}
