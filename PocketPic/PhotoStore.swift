//
//  PhotoStore.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import Foundation
import Combine

#if canImport(UIKit)
import Photos
#endif

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
        #if canImport(UIKit)
        if let imageData = image.jpegData(compressionQuality: 1.0) {
            try? imageData.write(to: imageURL)
            print("Saved high-quality image locally: \(imageData.count) bytes, size: \(image.size)")
            
            // Add to photos array and save metadata
            photos.append(photo)
            saveMetadata()
            
            // Save to Photos library
            saveToPhotosLibrary(image: image, albumName: targetAlbum)
        }
        #elseif canImport(AppKit)
        if let tiffData = image.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let imageData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) {
            try? imageData.write(to: imageURL)
            
            // Add to photos array and save metadata
            photos.append(photo)
            saveMetadata()
            
            // Save to Photos library (macOS)
            saveToPhotosLibrary(image: image, albumName: targetAlbum)
        }
        #endif
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
        print("macOS: loading local photos")
        loadLocalPhotos()
        #endif
    }
    
    private func fetchPhotosFromAlbum() {
        #if canImport(UIKit)
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
        #endif
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
        #if canImport(UIKit)
        // Try to delete from Photos library first
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.filename], options: nil).firstObject {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            }, completionHandler: { success, error in
                if let error = error {
                    print("Error deleting from Photos library: \(error)")
                }
            })
        }
        #endif
        
        // Remove local image file
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        try? FileManager.default.removeItem(at: imageURL)
        
        // Remove from array
        photos.removeAll { $0.id == photo.id }
        
        // Save metadata if using local storage
        if photos.allSatisfy({ !$0.filename.contains("-") }) {
            saveMetadata()
        }
    }
    
    func getLastPhoto() -> Photo? {
        return photos.sorted(by: { $0.date > $1.date }).first
    }
    
    func loadImage(for photo: Photo) -> PlatformImage? {
        #if canImport(UIKit)
        // PRIORITY: Load from local storage first (original high-quality images)
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        if let imageData = try? Data(contentsOf: imageURL),
           let localImage = UIImage(data: imageData) {
            print("Loaded high-quality image from local storage: \(imageData.count) bytes")
            return localImage
        }
        
        // Fallback: Try Photos library only if local storage fails
        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.filename], options: nil).firstObject {
            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true
            requestOptions.deliveryMode = .highQualityFormat
            requestOptions.resizeMode = .none  // Don't resize, get original size
            requestOptions.isNetworkAccessAllowed = true
            requestOptions.version = .original  // Get original version, not edited
            
            var resultImage: UIImage?
            // Request full resolution image for best quality
            imageManager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFill, options: requestOptions) { image, _ in
                resultImage = image
            }
            if let photosImage = resultImage {
                print("Loaded image from Photos library: \(photosImage.size)")
            }
            return resultImage
        }
        
        return nil
        #elseif canImport(AppKit)
        // For macOS, load from local storage
        let imageURL = photosDirectory.appendingPathComponent(photo.filename)
        guard let imageData = try? Data(contentsOf: imageURL) else { return nil }
        return NSImage(data: imageData)
        #endif
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
        #if canImport(UIKit)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { (status: PHAuthorizationStatus) in
            guard status == .authorized || status == .limited else { return }
            
            PHPhotoLibrary.shared().performChanges({
                // Create the asset
                let assetRequest: PHAssetCreationRequest = PHAssetCreationRequest.forAsset()
            if let imageData = image.jpegData(compressionQuality: 1.0) {
                assetRequest.addResource(with: .photo, data: imageData, options: nil)
            }
                
                // Get or create the album
                let albumFetchOptions = PHFetchOptions()
                albumFetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
                let albumFetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumFetchOptions)
                
                if let album = albumFetchResult.firstObject {
                    // Album exists, add to it
                    let albumChangeRequest: PHAssetCollectionChangeRequest? = PHAssetCollectionChangeRequest(for: album)
                    albumChangeRequest?.addAssets([assetRequest.placeholderForCreatedAsset!] as NSArray)
                } else {
                    // Create new album
                    let albumChangeRequest: PHAssetCollectionChangeRequest? = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    albumChangeRequest?.addAssets([assetRequest.placeholderForCreatedAsset!] as NSArray)
                }
            }, completionHandler: { success, error in
                if let error = error {
                    print("Error saving to Photos library: \(error)")
                }
            })
        }
        #elseif canImport(AppKit)
        // For macOS, we'll save to the user's Pictures folder with the album name
        let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let albumURL = picturesURL.appendingPathComponent(albumName, isDirectory: true)
        
        // Create album directory if it doesn't exist
        try? FileManager.default.createDirectory(at: albumURL, withIntermediateDirectories: true)
        
        // Save image to album directory
        let filename = "\(UUID().uuidString).jpg"
        let imageURL = albumURL.appendingPathComponent(filename)
        
        if let tiffData = image.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let imageData = bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
            try? imageData.write(to: imageURL)
        }
        #endif
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

