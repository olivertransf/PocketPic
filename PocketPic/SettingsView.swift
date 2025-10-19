//
//  SettingsView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import Photos

struct SettingsView: View {
    @EnvironmentObject var photoStore: PhotoStore
    @State private var selectedAlbum: String = "PocketPic"
    @State private var availableAlbums: [String] = ["PocketPic"]
    @State private var showingAlbumPicker = false
    @State private var showingPermissionAlert = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Photo Storage")) {
                    HStack {
                        Text("Save to Album")
                        Spacer()
                        Button(selectedAlbum) {
                            showingAlbumPicker = true
                        }
                        .foregroundColor(.blue)
                    }
                    
                    Text("Photos will be saved to the selected album in your Photos library")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section(header: Text("Camera Overlay")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Overlay Opacity")
                            Spacer()
                            Text("\(Int(photoStore.overlayOpacity * 100))%")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $photoStore.overlayOpacity, in: 0.1...1.0, step: 0.1) {
                            Text("Opacity")
                        } minimumValueLabel: {
                            Text("10%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } maximumValueLabel: {
                            Text("100%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .onChange(of: photoStore.overlayOpacity) { _, newValue in
                            photoStore.setOverlayOpacity(newValue)
                        }
                        
                        Text("Adjust how transparent the previous photo appears in the camera preview")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Total Photos")
                        Spacer()
                        Text("\(photoStore.photos.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                loadAvailableAlbums()
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPickerView(
                    availableAlbums: availableAlbums,
                    selectedAlbum: $selectedAlbum,
                    isPresented: $showingAlbumPicker
                )
            }
            .alert("Photos Permission Required", isPresented: $showingPermissionAlert) {
                Button("Settings") {
                    openAppSettings()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Please grant photo library access in Settings to select custom albums.")
            }
        }
    }
    
    private func loadAvailableAlbums() {
        #if canImport(UIKit)
        let status = PHPhotoLibrary.authorizationStatus()
        
        switch status {
        case .authorized, .limited:
            fetchAlbums()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        fetchAlbums()
                    } else {
                        showingPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showingPermissionAlert = true
        @unknown default:
            break
        }
        #elseif canImport(AppKit)
        // For macOS, we'll use a simpler approach
        availableAlbums = ["PocketPic", "Desktop", "Downloads"]
        #endif
    }
    
    private func fetchAlbums() {
        #if canImport(UIKit)
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        var albumNames: [String] = ["PocketPic"] // Default album
        
        albums.enumerateObjects { collection, _, _ in
            albumNames.append(collection.localizedTitle ?? "Untitled Album")
        }
        
        availableAlbums = albumNames
        #endif
    }
    
    
    private func openAppSettings() {
        #if canImport(UIKit)
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
        #endif
    }
}

struct AlbumPickerView: View {
    let availableAlbums: [String]
    @Binding var selectedAlbum: String
    @Binding var isPresented: Bool
    @EnvironmentObject var photoStore: PhotoStore
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Choose Album")) {
                    ForEach(availableAlbums, id: \.self) { album in
                        HStack {
                            Text(album)
                                .font(.body)
                            Spacer()
                            if selectedAlbum == album {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAlbum = album
                            photoStore.setTargetAlbum(album)
                            isPresented = false
                        }
                    }
                }
            }
            .navigationTitle("Select Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    SettingsView()
        .environmentObject(PhotoStore())
}
