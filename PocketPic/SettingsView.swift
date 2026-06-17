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
        NavigationStack {
            PocketPicSettingsForm {
                storageSection
                cameraSection
                overlaySection
                privacySection
                exportSection
                aboutSection
            }
            .navigationTitle("Settings")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .tint(Color.appAccent)
            .onAppear {
                selectedAlbum = photoStore.targetAlbum
                loadAvailableAlbums()
            }
            .onChange(of: showingAlbumPicker) { _, isShowing in
                if isShowing {
                    selectedAlbum = photoStore.targetAlbum
                    loadAvailableAlbums()
                }
            }
            .sheet(isPresented: $showingAlbumPicker) {
                NavigationStack {
                    AlbumPickerView(
                        availableAlbums: availableAlbums,
                        selectedAlbum: $selectedAlbum,
                        isPresented: $showingAlbumPicker
                    )
                    .environmentObject(photoStore)
                }
                #if canImport(UIKit)
                .presentationDetents([.medium, .large])
                .pocketPicSheetChrome()
                #else
                .pocketPicModalPresentation(.albumPicker)
                #endif
            }
            .alert("Photos Permission Required", isPresented: $showingPermissionAlert) {
                Button("Settings") { openAppSettings() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Please grant photo library access in Settings to select custom albums.")
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent("Save to Album") {
                Button(selectedAlbum) { showingAlbumPicker = true }
            }
        } header: {
            Text("Photo Storage")
        } footer: {
            Text("Photos are saved to this album in your Photos library.")
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        Section {
            #if os(macOS)
            Picker("Default Camera", selection: Binding(
                get: { photoStore.defaultCameraPosition },
                set: { photoStore.setDefaultCameraPosition($0) }
            )) {
                Text("Front").tag("front")
                Text("Back").tag("back")
            }
            .pickerStyle(.segmented)
            #else
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
            #endif
        } header: {
            Text("Camera")
        } footer: {
            Text("Which camera opens when you start a session.")
        }
    }

    @ViewBuilder
    private var overlaySection: some View {
        Section {
            PocketPicSettingsSlider(
                title: "Overlay Opacity",
                value: $photoStore.overlayOpacity,
                range: 0.1...1.0,
                step: 0.1,
                suffix: { "\(Int($0 * 100))%" }
            )
            .onChange(of: photoStore.overlayOpacity) { _, newValue in
                photoStore.setOverlayOpacity(newValue)
            }
        } header: {
            Text("Camera Overlay")
        } footer: {
            Text("How transparent the previous photo appears in the camera viewfinder.")
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            PocketPicSettingsToggle(
                title: "Hide Photos",
                subtitle: "Gallery shows placeholders instead of your photos.",
                isOn: Binding(
                    get: { photoStore.hidePhotosInGallery },
                    set: { photoStore.setHidePhotosInGallery($0) }
                )
            )
        } header: {
            Text("Privacy")
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section {
            PocketPicSettingsToggle(
                title: "Native Resolution",
                subtitle: "HEVC at full sensor resolution. Off uses 1080p H.264.",
                isOn: Binding(
                    get: { photoStore.useNativeResolution },
                    set: { photoStore.setUseNativeResolution($0) }
                )
            )
        } header: {
            Text("Export")
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            LabeledContent("Photos", value: "\(photoStore.photos.count)")
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            #if canImport(UIKit)
            Button {
                if let url = URL(string: "itms-apps://itunes.apple.com/app/idYOUR_APP_ID?action=write-review") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    Text("Rate PocketPic")
                    Spacer()
                    Image(systemName: "star.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            #endif
        } header: {
            Text("About")
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
        
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
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
        List {
            Section {
                Button {
                    newAlbumName = ""
                    showNewAlbumAlert = true
                } label: {
                    Label("New Album", systemImage: "plus.circle.fill")
                }
            }

            Section("My Albums") {
                ForEach(albums, id: \.self) { album in
                    Button {
                        selectedAlbum = album
                        photoStore.setTargetAlbum(album)
                        isPresented = false
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(album)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedAlbum == album {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.plain)
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
        .onChange(of: availableAlbums) { _, updated in
            albums = updated
        }
        #elseif canImport(AppKit)
        List {
            Section {
                Button {
                    newAlbumName = ""
                    showNewAlbumAlert = true
                } label: {
                    Label("New Album", systemImage: "plus.circle.fill")
                }
            }

            Section("My Albums") {
                ForEach(albums, id: \.self) { album in
                    Button {
                        selectedAlbum = album
                        photoStore.setTargetAlbum(album)
                        isPresented = false
                    } label: {
                        HStack {
                            Image(systemName: "photo.on.rectangle")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(album)
                            Spacer()
                            if selectedAlbum == album {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.plain)
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
        .onChange(of: availableAlbums) { _, updated in
            albums = updated
        }
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
