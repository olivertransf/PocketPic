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
    @State private var sortOption: SortOption = .newestFirst
    @State private var isSelectionMode = false
    @State private var selectedPhotos: Set<Photo.ID> = []
    @State private var showDeleteConfirmation = false
    
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 8)
    ]
    
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
                if photoStore.photos.isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 70))
                            .foregroundColor(.secondary)
                        
                        Text("No Photos Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Take your first selfie to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(sortedPhotos) { photo in
                                ZStack(alignment: .topTrailing) {
                                    PhotoThumbnailView(photo: photo)
                                        .onTapGesture {
                                            if isSelectionMode {
                                                toggleSelection(photo: photo)
                                            }
                                        }
                                    
                                    // Selection overlay
                                    if isSelectionMode {
                                        Circle()
                                            .fill(selectedPhotos.contains(photo.id) ? Color.blue : Color.white)
                                            .frame(width: 30, height: 30)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: 2)
                                            )
                                            .overlay(
                                                Image(systemName: selectedPhotos.contains(photo.id) ? "checkmark" : "")
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 14, weight: .bold))
                                            )
                                            .padding(8)
                                    }
                                }
                                .contextMenu {
                                    if !isSelectionMode {
                                        Button(role: .destructive) {
                                            withAnimation {
                                                photoStore.deletePhoto(photo)
                                            }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(isSelectionMode ? "\(selectedPhotos.count) Selected" : "Gallery")
            .toolbar {
                #if canImport(UIKit)
                ToolbarItem(placement: .navigationBarLeading) {
                    if isSelectionMode {
                        Button("Cancel") {
                            exitSelectionMode()
                        }
                    } else {
                        Button(action: {
                            photoStore.refreshPhotos()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                #elseif canImport(AppKit)
                ToolbarItem(placement: .navigation) {
                    if isSelectionMode {
                        Button("Cancel") {
                            exitSelectionMode()
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
                    HStack(spacing: 16) {
                        if isSelectionMode {
                            Button(action: {
                                if selectedPhotos.count == sortedPhotos.count {
                                    selectedPhotos.removeAll()
                                } else {
                                    selectedPhotos = Set(sortedPhotos.map { $0.id })
                                }
                            }) {
                                Text(selectedPhotos.count == sortedPhotos.count ? "Deselect All" : "Select All")
                            }
                            
                            Button(role: .destructive, action: {
                                showDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                            }
                            .disabled(selectedPhotos.isEmpty)
                        } else {
                            Menu {
                                ForEach(SortOption.allCases, id: \.self) { option in
                                    Button(action: { sortOption = option }) {
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
                            
                            Button(action: {
                                isSelectionMode = true
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

struct PhotoThumbnailView: View {
    @EnvironmentObject var photoStore: PhotoStore
    let photo: Photo
    
    var body: some View {
        GeometryReader { geometry in
            if let image = photoStore.loadImage(for: photo) {
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .clipped()
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                #elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .clipped()
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                #endif
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .cornerRadius(8)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}


#Preview {
    GalleryView()
        .environmentObject(PhotoStore())
}

