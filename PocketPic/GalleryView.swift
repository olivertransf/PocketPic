//
//  GalleryView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI

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
    
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 12)
    ]
    
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
                    // Modern empty state
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.blue.opacity(0.1), .purple.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 120, height: 120)
                            
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 50))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        
                        VStack(spacing: 8) {
                            Text("No Photos Yet")
                                .font(.title2)
                                .fontWeight(.bold)
                            
                            Text("Take your first selfie to get started")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(sortedPhotos) { photo in
                                PhotoThumbnailCard(photo: photo, isSelected: selectedPhotos.contains(photo.id), isSelectionMode: isSelectionMode)
                                    .onTapGesture {
                                        if isSelectionMode {
                                            withAnimation(.spring(response: 0.3)) {
                                                toggleSelection(photo: photo)
                                            }
                                        }
                                    }
                                    .contextMenu {
                                        if !isSelectionMode {
                                            Button(role: .destructive) {
                                                withAnimation(.spring()) {
                                                    photoStore.deletePhoto(photo)
                                                }
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedPhotos.count) Selected" : "Gallery")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.large)
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
                        Button(action: {
                            photoStore.refreshPhotos()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .symbolEffect(.pulse, options: .speed(2))
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
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                #endif
                
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        if isSelectionMode {
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
                            
                            Button(role: .destructive, action: {
                                showDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                            }
                            .disabled(selectedPhotos.isEmpty)
                        } else {
                            Menu {
                                Button(action: {
                                    showExportSheet = true
                                }) {
                                    Label("Export Montage", systemImage: "film")
                                }
                                .disabled(photoStore.photos.isEmpty)
                                
                                Divider()
                                
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
                                Image(systemName: "ellipsis.circle")
                            }
                            
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
                    ShareSheet(items: [videoURL])
                }
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
    let photo: Photo
    let isSelected: Bool
    let isSelectionMode: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = photoStore.loadImage(for: photo) {
                    #if canImport(UIKit)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected && isSelectionMode ? Color.blue : Color.clear, lineWidth: 3)
                        )
                    #elseif canImport(AppKit)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected && isSelectionMode ? Color.blue : Color.clear, lineWidth: 3)
                        )
                    #endif
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.secondary)
                                .font(.title3)
                        )
                }
                
                // Selection indicator
                if isSelectionMode {
                    VStack {
                        HStack {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Color.blue : Color.white.opacity(0.9))
                                    .frame(width: 28, height: 28)
                                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                                
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.system(size: 14, weight: .bold))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(8)
                        }
                        Spacer()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            .scaleEffect(isSelected && isSelectionMode ? 0.95 : 1.0)
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
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
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
            
            Text("1920×1080 • H.264 • 16:9")
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
                            AnyShapeStyle(LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )) :
                            AnyShapeStyle(Color.secondary.opacity(0.1))
                        )
                )
                .scaleEffect(exportViewModel.selectedFPS == fps ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var exportButton: some View {
        Group {
            if exportViewModel.isExporting {
                VStack(spacing: 20) {
                    ProgressView(value: exportViewModel.exportProgress) {
                        HStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Creating Video...")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                    }
                    .progressViewStyle(.linear)
                    .tint(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    
                    Text("\(Int(exportViewModel.exportProgress * 100))%")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.systemBackground)
                        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
                )
                .padding(.horizontal)
            } else {
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
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(18)
                    .shadow(color: .blue.opacity(0.4), radius: 14, x: 0, y: 6)
                }
                .padding(.horizontal)
                .buttonStyle(.plain)
            }
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
                }
            }
        }
    }
}

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
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // For macOS, we can use NSSharingServicePicker
        // But for simplicity, we'll just let the user manually save
    }
}
#endif

#Preview {
    GalleryView()
        .environmentObject(PhotoStore())
}
