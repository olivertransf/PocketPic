//
//  SettingsView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import Photos

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
                Section {
                    HStack {
                        Text("Save to Album")
                        Spacer()
                        Button(selectedAlbum) {
                            showingAlbumPicker = true
                        }
                        .foregroundStyle(Color.appAccent)
                        .fontWeight(.medium)
                    }
                } header: {
                    Text("Photo Storage")
                } footer: {
                    Text("Photos are saved to this album in your Photos library.")
                }

                Section {
                    HStack {
                        Text("Default Camera")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { photoStore.defaultCameraPosition },
                            set: { photoStore.setDefaultCameraPosition($0) }
                        )) {
                            Text("Front").tag("front")
                            Text("Back").tag("back")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Which camera opens when you start a session.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Overlay Opacity")
                            Spacer()
                            Text("\(Int(photoStore.overlayOpacity * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .font(.subheadline.monospacedDigit())
                        }
                        Slider(value: $photoStore.overlayOpacity, in: 0.1...1.0, step: 0.1)
                            .tint(Color.appAccent)
                            .onChange(of: photoStore.overlayOpacity) { _, newValue in
                                photoStore.setOverlayOpacity(newValue)
                            }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Camera Overlay")
                } footer: {
                    Text("How transparent the previous photo appears in the camera viewfinder.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { photoStore.hidePhotosInGallery },
                        set: { photoStore.setHidePhotosInGallery($0) }
                    )) {
                        Text("Hide Photos")
                    }
                    .tint(Color.appAccent)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Gallery shows placeholders instead of your photos.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { photoStore.useNativeResolution },
                        set: { photoStore.setUseNativeResolution($0) }
                    )) {
                        Text("Native Resolution")
                    }
                    .tint(Color.appAccent)
                } header: {
                    Text("Export")
                } footer: {
                    Text("Exports at the camera's full sensor resolution using HEVC. Standard mode outputs 1080p H.264.")
                }

                Section {
                    HStack {
                        Text("Photos")
                        Spacer()
                        Text("\(photoStore.photos.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let url = URL(string: "itms-apps://itunes.apple.com/app/idYOUR_APP_ID?action=write-review") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Text("Rate PocketPic")
                            Spacer()
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.appAccent)
            .onAppear {
                selectedAlbum = photoStore.targetAlbum
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
        NavigationStack {
            Form {
                Section("Photo Storage") {
                    LabeledContent("Save to Album") {
                        Button(selectedAlbum) {
                            showingAlbumPicker = true
                        }
                        .foregroundStyle(Color.appAccent)
                        .fontWeight(.medium)
                    }
                }

                Section("Camera") {
                    Picker("Default Camera", selection: Binding(
                        get: { photoStore.defaultCameraPosition },
                        set: { photoStore.setDefaultCameraPosition($0) }
                    )) {
                        Text("Front").tag("front")
                        Text("Back").tag("back")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Camera Overlay") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Overlay Opacity")
                            Spacer()
                            Text("\(Int(photoStore.overlayOpacity * 100))%")
                                .foregroundStyle(.secondary)
                                .font(.subheadline.monospacedDigit())
                        }
                        Slider(value: $photoStore.overlayOpacity, in: 0.1...1.0, step: 0.1)
                            .tint(Color.appAccent)
                            .onChange(of: photoStore.overlayOpacity) { _, newValue in
                                photoStore.setOverlayOpacity(newValue)
                            }
                    }
                    .padding(.vertical, 2)
                }

                Section("Privacy") {
                    Toggle("Hide Photos in Gallery", isOn: Binding(
                        get: { photoStore.hidePhotosInGallery },
                        set: { photoStore.setHidePhotosInGallery($0) }
                    ))
                    .tint(Color.appAccent)
                }

                Section("Export") {
                    Toggle("Native Resolution", isOn: Binding(
                        get: { photoStore.useNativeResolution },
                        set: { photoStore.setUseNativeResolution($0) }
                    ))
                    .tint(Color.appAccent)
                }

                Section("About") {
                    LabeledContent("Photos", value: "\(photoStore.photos.count)")
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .onAppear {
                selectedAlbum = photoStore.targetAlbum
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
        var seen = Set<String>()
        var albumNames: [String] = []
        
        if !seen.contains("PocketPic") {
            seen.insert("PocketPic")
            albumNames.append("PocketPic")
        }
        albums.enumerateObjects { collection, _, _ in
            let name = collection.localizedTitle ?? "Untitled Album"
            if !seen.contains(name) {
                seen.insert(name)
                albumNames.append(name)
            }
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

    @State private var albums: [String] = []
    @State private var showNewAlbumAlert = false
    @State private var newAlbumName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        #if canImport(UIKit)
        NavigationStack {
            List {
                Section {
                    Button {
                        newAlbumName = ""
                        showNewAlbumAlert = true
                    } label: {
                        Label("New Album", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.appAccent)
                            .fontWeight(.medium)
                    }
                }

                Section("My Albums") {
                    ForEach(albums, id: \.self) { album in
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(album)
                                .font(.body)
                            Spacer()
                            if selectedAlbum == album {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.appAccent)
                                    .font(.system(size: 15, weight: .semibold))
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
                    Button("Cancel") { isPresented = false }
                }
            }
            .alert("New Album", isPresented: $showNewAlbumAlert) {
                TextField("Album Name", text: $newAlbumName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createAlbum() }
            } message: {
                Text("Enter a name for the new Photos album.")
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
            .overlay {
                if isCreating {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        ProgressView("Creating…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .onAppear { albums = availableAlbums }
        }
        .pocketPicModalPresentation(.albumPicker)
        #elseif canImport(AppKit)
        NavigationStack {
            List {
                Button {
                    newAlbumName = ""
                    showNewAlbumAlert = true
                } label: {
                    Label("New Album", systemImage: "plus.circle.fill")
                        .foregroundStyle(Color.appAccent)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)

                Section("My Albums") {
                    ForEach(albums, id: \.self) { album in
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(album)
                            Spacer()
                            if selectedAlbum == album {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.appAccent)
                                    .font(.system(size: 13, weight: .semibold))
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.escape)
                }
            }
            .alert("New Album", isPresented: $showNewAlbumAlert) {
                TextField("Album Name", text: $newAlbumName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createAlbum() }
            } message: {
                Text("Enter a name for the new Photos album.")
            }
            .onAppear { albums = availableAlbums }
        }
        .pocketPicModalPresentation(.albumPicker)
        #endif
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        Task {
            let success = await photoStore.createAlbum(named: name)
            await MainActor.run {
                isCreating = false
                if success {
                    if !albums.contains(name) {
                        albums.insert(name, at: 1)
                    }
                    selectedAlbum = name
                    photoStore.setTargetAlbum(name)
                    isPresented = false
                } else {
                    errorMessage = "Could not create album \"\(name)\". Check Photos permissions in Settings."
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(PhotoStore())
}
