//
//  PhotoStorageManager.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/14/25.
//

import SwiftUI
import AVFoundation
import Combine

#if os(iOS)
import Photos
#endif

class PhotoStorageManager: ObservableObject {
    @Published var dailyPhotos: [DailyPhoto] = []
    @Published var previousPhoto: PlatformImage?
    
    private let albumName = "PocketPic Daily Selfies"
    #if os(iOS)
    private var assetCollection: PHAssetCollection?
    #endif
    
    init() {
        loadPhotos()
        loadPreviousPhoto()
    }
    
    func savePhoto(_ image: PlatformImage) {
        let photoData = PhotoData(image: image, date: Date())
        
        #if os(iOS)
        // Save to custom album in Photos app
        saveToPhotosAlbum(image) { [weak self] success, assetURL in
            if success {
                DispatchQueue.main.async {
                    self?.dailyPhotos.append(DailyPhoto(date: photoData.date, image: image))
                    self?.previousPhoto = image
                    self?.savePhotoMetadata()
                }
            }
        }
        #elseif os(macOS)
        // Save to local directory on macOS
        saveToLocalDirectory(image) { [weak self] success in
            if success {
                DispatchQueue.main.async {
                    self?.dailyPhotos.append(DailyPhoto(date: photoData.date, image: image))
                    self?.previousPhoto = image
                    self?.savePhotoMetadata()
                }
            }
        }
        #endif
    }
    
    #if os(iOS)
    private func saveToPhotosAlbum(_ image: PlatformImage, completion: @escaping (Bool, String?) -> Void) {
        // Request authorization
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else {
                completion(false, nil)
                return
            }
            
            // Get or create album
            self.getOrCreateAlbum { album in
                guard let album = album else {
                    completion(false, nil)
                    return
                }
                
                // Save photo to album
                PHPhotoLibrary.shared().performChanges({
                    let assetRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)
                    let assetPlaceholder = assetRequest.placeholderForCreatedAsset
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    let enumeration: NSArray = [assetPlaceholder!]
                    albumChangeRequest?.addAssets(enumeration)
                }) { success, error in
                    completion(success, nil)
                }
            }
        }
    }
    #endif
    
    #if os(iOS)
    private func getOrCreateAlbum(completion: @escaping (PHAssetCollection?) -> Void) {
        if let album = assetCollection {
            completion(album)
            return
        }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        if let album = collections.firstObject {
            assetCollection = album
            completion(album)
        } else {
            // Create new album
            PHPhotoLibrary.shared().performChanges({
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.albumName)
            }) { success, error in
                if success {
                    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
                    self.assetCollection = collections.firstObject
                    completion(self.assetCollection)
                } else {
                    completion(nil)
                }
            }
        }
    }
    #endif
    
    #if os(macOS)
    private func getPhotosDirectory() -> URL {
        let paths = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
        let picturesDirectory = paths[0]
        let pocketPicDirectory = picturesDirectory.appendingPathComponent("PocketPic Daily Selfies")
        
        if !FileManager.default.fileExists(atPath: pocketPicDirectory.path) {
            try? FileManager.default.createDirectory(at: pocketPicDirectory, withIntermediateDirectories: true)
        }
        
        return pocketPicDirectory
    }
    
    private func saveToLocalDirectory(_ image: PlatformImage, completion: @escaping (Bool) -> Void) {
        let directory = getPhotosDirectory()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "selfie_\(dateFormatter.string(from: Date())).png"
        let fileURL = directory.appendingPathComponent(filename)
        
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            completion(false)
            return
        }
        
        do {
            try pngData.write(to: fileURL)
            completion(true)
        } catch {
            print("Error saving image: \(error)")
            completion(false)
        }
    }
    #endif
    
    private func savePhotoMetadata() {
        let metadata = dailyPhotos.map { photo in
            ["date": photo.date.timeIntervalSince1970]
        }
        UserDefaults.standard.set(metadata, forKey: "dailyPhotosMetadata")
    }
    
    private func loadPhotos() {
        guard let metadata = UserDefaults.standard.array(forKey: "dailyPhotosMetadata") as? [[String: Double]] else {
            return
        }
        
        for data in metadata {
            if let _ = data["date"] {
                // We'll load actual images from Photos library when needed
            }
        }
    }
    
    private func loadPreviousPhoto() {
        #if os(iOS)
        // Get the most recent photo from our album
        getOrCreateAlbum { [weak self] album in
            guard let album = album else { return }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.fetchLimit = 1
            
            let assets = PHAsset.fetchAssets(in: album, options: fetchOptions)
            
            if let asset = assets.firstObject {
                let manager = PHImageManager.default()
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                options.deliveryMode = .highQualityFormat
                
                manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { image, _ in
                    DispatchQueue.main.async {
                        self?.previousPhoto = image
                    }
                }
            }
        }
        #elseif os(macOS)
        // Load most recent photo from local directory
        let directory = getPhotosDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 > date2
            }
            
            if let mostRecent = sortedFiles.first,
               let image = NSImage(contentsOf: mostRecent) {
                DispatchQueue.main.async {
                    self.previousPhoto = image
                }
            }
        } catch {
            print("Error loading previous photo: \(error)")
        }
        #endif
    }
    
    func generateVideo(completion: @escaping (URL?) -> Void) {
        #if os(iOS)
        getOrCreateAlbum { [weak self] album in
            guard let album = album else {
                completion(nil)
                return
            }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            
            let assets = PHAsset.fetchAssets(in: album, options: fetchOptions)
            var images: [PlatformImage] = []
            let manager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            
            assets.enumerateObjects { asset, _, _ in
                manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { image, _ in
                    if let image = image {
                        images.append(image)
                    }
                }
            }
            
            guard !images.isEmpty else {
                completion(nil)
                return
            }
            
            self?.createVideoFromImages(images, completion: completion)
        }
        #elseif os(macOS)
        // Load images from local directory
        let directory = getPhotosDirectory()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            let sortedFiles = files.sorted { file1, file2 in
                let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date.distantPast
                return date1 < date2
            }
            
            var images: [PlatformImage] = []
            for file in sortedFiles {
                if let image = NSImage(contentsOf: file) {
                    images.append(image)
                }
            }
            
            guard !images.isEmpty else {
                completion(nil)
                return
            }
            
            self.createVideoFromImages(images, completion: completion)
        } catch {
            print("Error loading images: \(error)")
            completion(nil)
        }
        #endif
    }
    
    private func createVideoFromImages(_ images: [PlatformImage], completion: @escaping (URL?) -> Void) {
        guard let firstImage = images.first else {
            completion(nil)
            return
        }
        
        let size = firstImage.size
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("pocketpic_timelapse.mp4")
        
        // Remove existing file
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let videoWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            completion(nil)
            return
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ]
        
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoWriterInput, sourcePixelBufferAttributes: nil)
        
        videoWriter.add(videoWriterInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        var frameCount = 0
        
        for image in images {
            let presentationTime = CMTimeMake(value: Int64(frameCount), timescale: 10)
            
            while !videoWriterInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.1)
            }
            
            if let pixelBuffer = self.pixelBuffer(from: image, size: size) {
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            }
            
            frameCount += 1
        }
        
        videoWriterInput.markAsFinished()
        videoWriter.finishWriting {
            DispatchQueue.main.async {
                if videoWriter.status == .completed {
                    completion(outputURL)
                } else {
                    completion(nil)
                }
            }
        }
    }
    
    private func pixelBuffer(from image: PlatformImage, size: CGSize) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, attrs, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(data: pixelData, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            return nil
        }
        
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        
        #if os(iOS)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        UIGraphicsPopContext()
        #elseif os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        #endif
        
        return buffer
    }
}

struct DailyPhoto: Identifiable {
    let id = UUID()
    let date: Date
    let image: PlatformImage
}

struct PhotoData {
    let image: PlatformImage
    let date: Date
}

