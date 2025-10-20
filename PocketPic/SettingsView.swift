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
        #if canImport(UIKit)
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
            .navigationBarTitleDisplayMode(.inline)
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
        #elseif canImport(AppKit)
        NavigationView {
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
        #endif
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
        // macOS also has access to Photos library
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        switch status {
        case .authorized, .limited:
            fetchAlbums()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        fetchAlbums()
                    } else {
                        // Fallback to default albums
                        availableAlbums = ["PocketPic"]
                    }
                }
            }
        case .denied, .restricted:
            // Fallback to default albums
            availableAlbums = ["PocketPic"]
        @unknown default:
            availableAlbums = ["PocketPic"]
        }
        #endif
    }
    
    private func fetchAlbums() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
        
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        var albumNames: [String] = ["PocketPic"] // Default album
        
        albums.enumerateObjects { collection, _, _ in
            albumNames.append(collection.localizedTitle ?? "Untitled Album")
        }
        
        availableAlbums = albumNames
    }
    
    
    private func openAppSettings() {
        #if canImport(UIKit)
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
        #elseif canImport(AppKit)
        // On macOS, open System Preferences > Privacy & Security > Photos
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(settingsURL)
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
        #if canImport(UIKit)
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
        #elseif canImport(AppKit)
        NavigationView {
            VStack(spacing: 20) {
                Text("Select Album")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                List(availableAlbums, id: \.self) { album in
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
                .listStyle(PlainListStyle())
                
                HStack {
                    Spacer()
                    Button("Cancel") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)
                }
                .padding()
            }
            .frame(minWidth: 300, minHeight: 400)
        }
        #endif
    }
}

#Preview {
    SettingsView()
        .environmentObject(PhotoStore())
}
