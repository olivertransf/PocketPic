//
//  PhotoStore.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import Foundation
import Combine
import Photos

struct Photo: Identifiable, Codable {
    let id: UUID
    let date: Date
    let filename: String
    
    init(id: UUID = UUID(), date: Date = Date(), filename: String) {
        self.id = id
        self.date = date
        self.filename = filename
    }
}

@MainActor
class PhotoStore: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var targetAlbum: String = "PocketPic"
    @Published var overlayOpacity: Double = 0.4
    
    private let photosDirectory: URL
    private let metadataURL: URL
    private let settingsURL: URL
    
    init() {
        // Setup directories
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.photosDirectory = documentsDirectory.appendingPathComponent("PocketPicPhotos", isDirectory: true)
        self.metadataURL = documentsDirectory.appendingPathComponent("photos_metadata.json")
        self.settingsURL = documentsDirectory.appendingPathComponent("app_settings.json")
        
        // Create photos directory if needed
        try? FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        
        // Load existing photos and settings
        loadSettings()
        loadPhotosFromAlbum()
    }
    
    func savePhoto(_ image: PlatformImage) {
        let photo = Photo(filename: "\(UUID().uuidString).jpg")
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        
        // Save image to disk with maximum quality
        var saveSuccess = false
        
        #if canImport(UIKit)
        if let imageData = image.jpegData(compressionQuality: 1.0) {
            do {
                try imageData.write(to: imageURL)
                print("Saved high-quality image locally: \(imageData.count) bytes, size: \(image.size)")
                saveSuccess = true
            } catch {
                print("Error saving image to disk: \(error.localizedDescription)")
                return
            }
        } else {
            print("Error: Failed to generate JPEG data from image")
            return
        }
        #elseif canImport(AppKit)
        if let tiffData = image.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let imageData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) {
            do {
                try imageData.write(to: imageURL)
                print("Saved high-quality image locally: \(imageData.count) bytes")
                saveSuccess = true
            } catch {
                print("Error saving image to disk: \(error.localizedDescription)")
                return
            }
        } else {
            print("Error: Failed to generate JPEG data from image")
            return
        }
        #endif
        
        // Only add to photos array if save was successful
        if saveSuccess {
            photos.append(photo)
            saveMetadata()
            
            // Save to Photos library asynchronously (non-blocking)
            saveToPhotosLibrary(image: image, albumName: targetAlbum)
        }
    }
    
    func loadPhotosFromAlbum() {
        #if canImport(UIKit)
        let status = PHPhotoLibrary.authorizationStatus()
        print("Photos permission status: \(status.rawValue)")
        
        switch status {
        case .authorized, .limited:
            print("Photos permission granted, fetching from album")
            fetchPhotosFromAlbum()
        case .notDetermined:
            print("Photos permission not determined, requesting...")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { (status: PHAuthorizationStatus) in
                DispatchQueue.main.async {
                    print("Photos permission result: \(status.rawValue)")
                    if status == .authorized || status == .limited {
                        self.fetchPhotosFromAlbum()
                    } else {
                        print("Photos permission denied, loading local photos")
                        self.loadLocalPhotos()
                    }
                }
            }
        case .denied, .restricted:
            print("Photos permission denied/restricted, loading local photos")
            loadLocalPhotos()
        @unknown default:
            print("Unknown photos permission status, loading local photos")
            loadLocalPhotos()
        }
        #elseif canImport(AppKit)
        // macOS also has access to Photos library
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("macOS Photos permission status: \(status.rawValue)")
        
        switch status {
        case .authorized, .limited:
            print("macOS Photos permission granted, fetching from album")
            fetchPhotosFromAlbum()
        case .notDetermined:
            print("macOS Photos permission not determined, requesting...")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { (status: PHAuthorizationStatus) in
                DispatchQueue.main.async {
                    print("macOS Photos permission result: \(status.rawValue)")
                    if status == .authorized || status == .limited {
                        self.fetchPhotosFromAlbum()
                    } else {
                        print("macOS Photos permission denied, loading local photos")
                        self.loadLocalPhotos()
                    }
                }
            }
        case .denied, .restricted:
            print("macOS Photos permission denied/restricted, loading local photos")
            loadLocalPhotos()
        @unknown default:
            print("Unknown macOS Photos permission status, loading local photos")
            loadLocalPhotos()
        }
        #endif
    }
    
    private func fetchPhotosFromAlbum() {
        print("Fetching photos from album: \(targetAlbum)")
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Find the target album
        let albumFetchOptions = PHFetchOptions()
        albumFetchOptions.predicate = NSPredicate(format: "title = %@", targetAlbum)
        let albumFetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumFetchOptions)
        
        print("Found \(albumFetchResult.count) albums with name: \(targetAlbum)")
        
        if let album = albumFetchResult.firstObject {
            // Fetch photos from the specific album
            let assets = PHAsset.fetchAssets(in: album, options: fetchOptions)
            var albumPhotos: [Photo] = []
            
            print("Found \(assets.count) photos in album: \(targetAlbum)")
            
            assets.enumerateObjects { asset, _, _ in
                let photo = Photo(
                    id: UUID(uuidString: asset.localIdentifier) ?? UUID(),
                    date: asset.creationDate ?? Date(),
                    filename: asset.localIdentifier
                )
                albumPhotos.append(photo)
            }
            
            photos = albumPhotos
            print("Loaded \(photos.count) photos from album")
        } else {
            // Album doesn't exist, load local photos
            print("Album '\(targetAlbum)' not found, loading local photos")
            loadLocalPhotos()
        }
    }
    
    private func loadLocalPhotos() {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            photos = []
            return
        }
        
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            photos = try decoder.decode([Photo].self, from: data)
        } catch {
            print("Error loading photos metadata: \(error)")
            photos = []
        }
    }
    
    func deletePhoto(_ photo: Photo) {
        // Try to delete from Photos library first (works on both iOS and macOS)
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.filename], options: nil).firstObject {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }, completionHandler: { success, error in
                if let error = error {
                    print("Error deleting from Photos library: \(error.localizedDescription)")
                } else if success {
                    print("Successfully deleted photo from Photos library")
                }
            })
        }
        
        // Remove local image file
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        do {
            if FileManager.default.fileExists(atPath: imageURL.path) {
                try FileManager.default.removeItem(at: imageURL)
                print("Successfully deleted local image file")
            }
        } catch {
            print("Error deleting local image file: \(error.localizedDescription)")
            // Continue with removing from array even if file deletion fails
        }
        
        // Remove from array
        photos.removeAll { $0.id == photo.id }
        
        // Always save metadata after deletion
        saveMetadata()
    }
    
    func getLastPhoto() -> Photo? {
        return photos.sorted(by: { $0.date > $1.date }).first
    }
    
    func loadImage(for photo: Photo) -> PlatformImage? {
        #if canImport(UIKit)
        // PRIORITY: Load from local storage first (original high-quality images)
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        
        // Check if file exists before trying to load
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            // Try Photos library fallback
            return loadImageFromPhotosLibrary(identifier: photo.filename)
        }
        
        do {
            let imageData = try Data(contentsOf: imageURL)
            guard let localImage = UIImage(data: imageData) else {
                print("Error: Failed to create UIImage from data")
                return loadImageFromPhotosLibrary(identifier: photo.filename)
            }
            print("Loaded high-quality image from local storage: \(imageData.count) bytes")
            return localImage
        } catch {
            print("Error loading image from local storage: \(error.localizedDescription)")
            return loadImageFromPhotosLibrary(identifier: photo.filename)
        }
        #elseif canImport(AppKit)
        // PRIORITY: Load from local storage first (original high-quality images)
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        
        // Check if file exists before trying to load
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            // Try Photos library fallback
            return loadImageFromPhotosLibrary(identifier: photo.filename)
        }
        
        do {
            let imageData = try Data(contentsOf: imageURL)
            guard let localImage = NSImage(data: imageData) else {
                print("Error: Failed to create NSImage from data")
                return loadImageFromPhotosLibrary(identifier: photo.filename)
            }
            print("Loaded high-quality image from local storage: \(imageData.count) bytes")
            return localImage
        } catch {
            print("Error loading image from local storage: \(error.localizedDescription)")
            return loadImageFromPhotosLibrary(identifier: photo.filename)
        }
        #endif
    }
    
    private func loadImageFromPhotosLibrary(identifier: String) -> PlatformImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        
        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = true
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .none
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.version = .original
        
        var resultImage: PlatformImage?
        
        #if canImport(UIKit)
        imageManager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFill, options: requestOptions) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                print("Error loading from Photos library: \(error.localizedDescription)")
            }
            resultImage = image
        }
        if let photosImage = resultImage {
            print("Loaded image from Photos library: \(photosImage.size)")
        }
        #elseif canImport(AppKit)
        imageManager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFill, options: requestOptions) { image, info in
            if let error = info?[PHImageErrorKey] as? Error {
                print("Error loading from Photos library: \(error.localizedDescription)")
            }
            resultImage = image
        }
        if let photosImage = resultImage {
            print("Loaded image from Photos library (iCloud): \(photosImage.size)")
        }
        #endif
        
        return resultImage
    }
    
    func getPhotoURL(for photo: Photo) -> URL {
        return photosDirectory.appendingPathComponent(photo.filename)
    }
    
    func setTargetAlbum(_ albumName: String) {
        targetAlbum = albumName
        saveSettings()
        loadPhotosFromAlbum()
    }
    
    func setOverlayOpacity(_ opacity: Double) {
        overlayOpacity = opacity
        saveSettings()
    }
    
    func refreshPhotos() {
        print("Refreshing photos from album: \(targetAlbum)")
        loadPhotosFromAlbum()
    }
    
    
    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: settingsURL)
            let decoder = JSONDecoder()
            let settings = try decoder.decode(AppSettings.self, from: data)
            targetAlbum = settings.targetAlbum
            overlayOpacity = settings.overlayOpacity
        } catch {
            print("Error loading settings: \(error)")
        }
    }
    
    private func saveSettings() {
        do {
            let settings = AppSettings(targetAlbum: targetAlbum, overlayOpacity: overlayOpacity)
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL)
        } catch {
            print("Error saving settings: \(error)")
        }
    }
    
    private func saveToPhotosLibrary(image: PlatformImage, albumName: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] (status: PHAuthorizationStatus) in
            guard status == .authorized || status == .limited else { 
                print("Photos library authorization denied")
                return 
            }
            
            // Get image data
            var imageData: Data?
            
            #if canImport(UIKit)
            imageData = image.jpegData(compressionQuality: 1.0)
            #elseif canImport(AppKit)
            if let tiffData = image.tiffRepresentation,
               let bitmapImage = NSBitmapImageRep(data: tiffData) {
                imageData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
            }
            #endif
            
            guard let imageData = imageData else {
                print("Error: Failed to generate image data for Photos library")
                return
            }
            
            PHPhotoLibrary.shared().performChanges({
                // Create the asset
                let assetRequest: PHAssetCreationRequest = PHAssetCreationRequest.forAsset()
                assetRequest.addResource(with: .photo, data: imageData, options: nil)
                
                // Get or create the album
                let albumFetchOptions = PHFetchOptions()
                albumFetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
                let albumFetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumFetchOptions)
                
                if let album = albumFetchResult.firstObject {
                    // Album exists, add to it
                    let albumChangeRequest: PHAssetCollectionChangeRequest? = PHAssetCollectionChangeRequest(for: album)
                    if let placeholder = assetRequest.placeholderForCreatedAsset {
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                        print("Added photo to existing album: \(albumName)")
                    }
                } else {
                    // Create new album
                    let albumChangeRequest: PHAssetCollectionChangeRequest? = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    if let placeholder = assetRequest.placeholderForCreatedAsset {
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                        print("Created new album and added photo: \(albumName)")
                    }
                }
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("Error saving to Photos library: \(error.localizedDescription)")
                    } else if success {
                        print("Successfully saved photo to Photos library album: \(albumName)")
                        // Refresh photos to sync with Photos library
                        self?.refreshPhotos()
                    }
                }
            })
        }
    }
    
    private func saveMetadata() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(photos)
            try data.write(to: metadataURL)
        } catch {
            print("Error saving photos metadata: \(error)")
        }
    }
}

struct AppSettings: Codable {
    let targetAlbum: String
    let overlayOpacity: Double
}

