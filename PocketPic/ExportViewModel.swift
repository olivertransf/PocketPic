//
//  ExportViewModel.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import AVFoundation
import Combine

#if canImport(UIKit)
import UIKit
import Photos
#elseif canImport(AppKit)
import AppKit
import PhotosUI
#endif

@MainActor
class ExportViewModel: ObservableObject {
    @Published var isExporting = false
    @Published var exportProgress: Double = 0.0
    @Published var showShareSheet = false
    @Published var exportedVideoURL: URL?
    @Published var errorMessage: String?
    @Published var selectedFPS: Int = 10
    
    let availableFPSOptions = [5, 10, 15, 24, 30, 60]
    
    func exportVideo(photos: [Photo], photoStore: PhotoStore) async {
        guard !photos.isEmpty else {
            errorMessage = "No photos to export"
            return
        }
        
        isExporting = true
        exportProgress = 0.0
        
        do {
            let videoURL = try await createVideo(from: photos, photoStore: photoStore)
            exportedVideoURL = videoURL
            showShareSheet = true
            isExporting = false
        } catch {
            errorMessage = "Failed to create video: \(error.localizedDescription)"
            isExporting = false
        }
    }
    
    private func createVideo(from photos: [Photo], photoStore: PhotoStore) async throws -> URL {
        let sortedPhotos = photos.sorted { $0.date < $1.date }
        
        // Setup output URL
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPic_\(Date().timeIntervalSince1970).mp4")
        
        // Remove existing file if needed
        try? FileManager.default.removeItem(at: outputURL)
        
        // Video settings
        let videoWidth: Int = 1920
        let videoHeight: Int = 1080
        let fps: Int32 = Int32(selectedFPS)
        
        // Setup video writer
        let videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]
        
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        guard videoWriter.canAdd(videoWriterInput) else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        
        videoWriter.add(videoWriterInput)
        
        // Start writing
        guard videoWriter.startWriting() else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot start writing"])
        }
        
        videoWriter.startSession(atSourceTime: .zero)
        
        // Add frames
        var frameCount: Int64 = 0
        
        for (index, photo) in sortedPhotos.enumerated() {
            autoreleasepool {
                guard let image = photoStore.loadImage(for: photo) else { return }
                
                let presentationTime = CMTime(value: frameCount, timescale: fps)
                
                // Wait for input to be ready
                while !videoWriterInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                
                if let pixelBuffer = createPixelBuffer(from: image, size: CGSize(width: videoWidth, height: videoHeight)) {
                    pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                    frameCount += 1
                    
                    Task { @MainActor in
                        self.exportProgress = Double(index + 1) / Double(sortedPhotos.count)
                    }
                }
            }
        }
        
        // Finish writing
        videoWriterInput.markAsFinished()
        
        await videoWriter.finishWriting()
        
        guard videoWriter.status == .completed else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video writing failed"])
        }
        
        return outputURL
    }
    
    private func createPixelBuffer(from image: PlatformImage, size: CGSize) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: pixelData,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        // Draw image scaled to fit
        context.clear(CGRect(origin: .zero, size: size))
        
        let imageSize = image.size
        let imageAspect = imageSize.width / imageSize.height
        let videoAspect = size.width / size.height
        
        var drawRect: CGRect
        if imageAspect > videoAspect {
            // Image is wider - fit to height
            let scaledWidth = size.height * imageAspect
            let xOffset = (size.width - scaledWidth) / 2
            drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: size.height)
        } else {
            // Image is taller - fit to width
            let scaledHeight = size.width / imageAspect
            let yOffset = (size.height - scaledHeight) / 2
            drawRect = CGRect(x: 0, y: yOffset, width: size.width, height: scaledHeight)
        }
        
        // Get CGImage from platform image
        #if canImport(UIKit)
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: drawRect)
        }
        #elseif canImport(AppKit)
        var proposedRect = CGRect(origin: .zero, size: imageSize)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            context.draw(cgImage, in: drawRect)
        }
        #endif
        
        return buffer
    }
    
    func saveToPhotos(videoURL: URL) async {
        #if canImport(UIKit)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        
        guard status == .authorized else {
            errorMessage = "Photo library access denied"
            return
        }
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }
        } catch {
            errorMessage = "Failed to save to Photos: \(error.localizedDescription)"
        }
        #elseif canImport(AppKit)
        // On macOS, we'll just let the user save via the share sheet
        // Photos library access is more restricted on macOS
        errorMessage = "Use the share sheet to save to Photos or Files"
        #endif
    }
}

