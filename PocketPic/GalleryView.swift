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
    
    /// Column count grows with window width; cell size stays between ~96–168 pt.
    private var galleryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 96, maximum: 168), spacing: 3)]
    }
    
    private var groupedBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.clear
        #endif
    }
    
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
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.systemGroupedBackground
                    .ignoresSafeArea()
                
                if photoStore.photos.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(Color.appAccent)

                        VStack(spacing: 6) {
                            Text("No Photos Yet")
                                .font(.headline)

                            Text("Open the Camera tab to take your first photo.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 80)
                    .padding(.horizontal, 40)
                    .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: galleryColumns, spacing: 3) {
                            ForEach(sortedPhotos) { photo in
                                PhotoThumbnailCard(
                                    photo: photo,
                                    isSelected: selectedPhotos.contains(photo.id),
                                    isSelectionMode: isSelectionMode
                                )
                                .onTapGesture {
                                    if isSelectionMode {
                                        withAnimation(.spring(response: 0.3)) {
                                            toggleSelection(photo: photo)
                                        }
                                    } else {
                                        detailPhoto = photo
                                    }
                                }
                                .onLongPressGesture(minimumDuration: 0.4) {
                                    if !isSelectionMode {
                                        deleteTargetPhoto = photo
                                        showSingleDeleteConfirmation = true
                                    }
                                }
                                .contextMenu {
                                    if !isSelectionMode {
                                        Button {
                                            detailPhoto = photo
                                        } label: {
                                            Label("View Photo", systemImage: "photo")
                                        }
                                        Button {
                                            showEyeDetectionPhoto = photo
                                        } label: {
                                            Label("Detect Eye Positions", systemImage: "eye")
                                        }
                                        .disabled(!photoStore.canLoadImage(for: photo))
                                        Divider()
                                        Button(role: .destructive) {
                                            deleteTargetPhoto = photo
                                            showSingleDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 1)
                    }
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedPhotos.count) Selected" : "Gallery")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if canImport(UIKit)
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        Button("Cancel") {
                            withAnimation(.spring()) {
                                exitSelectionMode()
                            }
                        }
                    } else {
                        HStack(spacing: 16) {
                            Toggle(isOn: Binding(
                                get: { photoStore.hidePhotosInGallery },
                                set: { photoStore.setHidePhotosInGallery($0) }
                            )) {
                                Image(systemName: photoStore.hidePhotosInGallery ? "eye.slash" : "eye")
                            }
                            .labelsHidden()
                            Button(action: {
                                photoStore.refreshPhotos()
                            }) {
                                if photoStore.isLoadingPhotoList {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .symbolEffect(.pulse, options: .speed(2))
                                }
                            }
                            .disabled(photoStore.isLoadingPhotoList)
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
                        #if canImport(AppKit)
                        .controlSize(.large)
                        #endif
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
                }
            }
            .alert("Delete Photos", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete \(selectedPhotos.count) Photo\(selectedPhotos.count == 1 ? "" : "s")", role: .destructive) {
                    deleteSelectedPhotos()
                }
            } message: {
                Text("Are you sure you want to delete \(selectedPhotos.count) photo\(selectedPhotos.count == 1 ? "" : "s")? This action cannot be undone.")
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
            .onChange(of: exportViewModel.showShareSheet) { oldValue, newValue in
                if newValue && showExportSheet {
                    // Dismiss export sheet first, then show share sheet
                    pendingShareSheet = true
                    showExportSheet = false
                }
            }
            .onChange(of: showExportSheet) { oldValue, newValue in
                if !newValue && pendingShareSheet {
                    // Export sheet dismissed, now show share sheet
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
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
            .fullScreenCover(item: $detailPhoto) { photo in
                PhotoDetailView(photo: photo)
                    .environmentObject(photoStore)
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
    }
    
    private func toggleSelection(photo: Photo) {
        if selectedPhotos.contains(photo.id) {
            selectedPhotos.remove(photo.id)
        } else {
            selectedPhotos.insert(photo.id)
        }
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

                // Date badge — bottom leading
                if !photoStore.hidePhotosInGallery {
                    VStack {
                        Spacer()
                        HStack {
                            Text(photo.date, format: .dateTime.month(.abbreviated).day())
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                                .padding(6)
                            Spacer()
                        }
                    }
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
    
    
    private var emptyStateView: some View {
        VStack(spacing: 32) {
            Image(systemName: "film")
                .font(.system(size: 60))
                .foregroundStyle(Color.appAccent)
            
            VStack(spacing: 12) {
                Text("No Photos to Export")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Take some selfies first to create your montage")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.top, 120)
        .padding(.bottom, 40)
    }
    
    private var headerCard: some View {
        VStack(spacing: 16) {
            Text("\(photoStore.photos.count) \(photoStore.photos.count == 1 ? "Photo" : "Photos")")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Duration: \(String(format: "%.1f", videoDuration))s • Size: \(estimatedFileSize)")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.systemBackground)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal)
    }
    
    private var fpsSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frame Rate")
                .font(.headline)
                .fontWeight(.semibold)
            
            HStack(spacing: 10) {
                ForEach(exportViewModel.availableFPSOptions, id: \.self) { fps in
                    fpsButton(fps: fps)
                }
            }
            
            Text(photoStore.useNativeResolution ? "Native resolution • HEVC" : "Auto orientation • H.264 • 1080p")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.systemBackground)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal)
    }
    
    private var alignEyesCard: some View {
        Toggle(isOn: $exportViewModel.alignEyes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Align eyes")
                    .font(.headline)
                    .fontWeight(.semibold)
                Text("Line up eyes across frames for a smoother montage")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.systemBackground)
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal)
    }
    
    private func fpsButton(fps: Int) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                exportViewModel.selectedFPS = fps
            }
        }) {
            Text("\(fps)")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(exportViewModel.selectedFPS == fps ? .white : .primary)
                .frame(width: 50, height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            exportViewModel.selectedFPS == fps ?
                            AnyShapeStyle(Color.appAccent) :
                            AnyShapeStyle(Color.secondary.opacity(0.12))
                        )
                )
                .scaleEffect(exportViewModel.selectedFPS == fps ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var exportButton: some View {
        Button(action: {
            Task {
                await exportViewModel.exportVideo(photos: photoStore.photos, photoStore: photoStore)
            }
        }) {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("Export Montage")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color.appAccent)
            .cornerRadius(18)
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        }
        .padding(.horizontal)
        .buttonStyle(.plain)
        .disabled(exportViewModel.isExporting)
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                if exportViewModel.isPreparing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.4)
                        .tint(.white)
                        .frame(width: 110, height: 110)
                } else {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 8)
                            .frame(width: 110, height: 110)

                        Circle()
                            .trim(from: 0, to: exportViewModel.exportProgress)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .frame(width: 110, height: 110)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: exportViewModel.exportProgress)

                        Text("\(Int(exportViewModel.exportProgress * 100))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }

                VStack(spacing: 8) {
                    Text(exportViewModel.isPreparing ? "Preparing…" : "Creating Montage")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .animation(.none, value: exportViewModel.isPreparing)

                    Text("This may take a moment…")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(.ultraThinMaterial)
            )
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    if photoStore.photos.isEmpty {
                        emptyStateView
                    } else {
                        headerCard
                        alignEyesCard
                        fpsSelectionCard
                        exportButton
                    }
                }
                .padding(.vertical, 16)
                .padding(.bottom, 20)
            }
            .background(Color.systemGroupedBackground)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 0)
            }
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
    }
}

struct ExportCompleteSheet: View {
    let videoURL: URL
    @ObservedObject var exportViewModel: ExportViewModel
    let onDismiss: () -> Void

    @State private var showShareSheet = false
    @State private var isPreparingShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent.opacity(0.12))
                            .frame(width: 100, height: 100)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(Color.appAccent)
                    }

                    VStack(spacing: 6) {
                        Text("Montage Ready")
                            .font(.title3)
                            .fontWeight(.bold)
                        Text("Your time-lapse video has been created.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        isPreparingShare = true
                        DispatchQueue.main.async {
                            showShareSheet = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Share")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.appAccent)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparingShare)

                    #if os(macOS)
                    Button {
                        SaveToFileHelper.showSavePanel(
                            sourceURL: videoURL,
                            onSuccess: { exportViewModel.showShareSheet = false },
                            onError: { exportViewModel.errorMessage = $0 }
                        )
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Save to File…")
                                .font(.headline)
                        }
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    #endif

                    Button("Done") {
                        onDismiss()
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(Color.systemGroupedBackground)
            .navigationTitle("Export Complete")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                        .fontWeight(.medium)
                        .disabled(isPreparingShare)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 320, minHeight: 340)
        #endif
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if canImport(AppKit)
            .frame(minWidth: 560, minHeight: 560)
            .presentationSizing(.fitted)
            #endif
        }
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
        .background(Color.black.opacity(0.05))
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

#Preview {
    GalleryView()
        .environmentObject(PhotoStore())
}
