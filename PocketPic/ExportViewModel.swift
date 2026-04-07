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
    @Published var isPreparing = false
    @Published var exportProgress: Double = 0.0
    @Published var showShareSheet = false
    @Published var exportedVideoURL: URL?
    @Published var errorMessage: String?
    @Published var selectedFPS: Int = 10
    @Published var alignEyes: Bool = true
    
    let availableFPSOptions = [5, 10, 15, 24, 30, 60]
    
    func exportVideo(photos: [Photo], photoStore: PhotoStore) async {
        guard !photos.isEmpty else {
            errorMessage = "No photos to export"
            return
        }

        isExporting = true
        isPreparing = true
        exportProgress = 0.0

        // Yield so SwiftUI can render the overlay before we block the main thread loading images
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — enough for a frame to render

        // Capture all main-actor state before leaving the main thread
        let fps = selectedFPS
        let shouldAlignEyes = alignEyes
        let useNative = photoStore.useNativeResolution
        let sortedPhotos = photos.sorted { $0.date < $1.date }

        var loadedImages: [PlatformImage] = []
        for photo in sortedPhotos {
            if let img = await photoStore.loadImageAsync(for: photo) {
                loadedImages.append(img)
            }
        }

        isPreparing = false

        guard !loadedImages.isEmpty else {
            errorMessage = "Could not load any photos"
            isExporting = false
            return
        }

        do {
            // All heavy encoding work runs off the main thread
            let videoURL = try await Task.detached(priority: .userInitiated) { [weak self] in
                try await ExportViewModel.encodeVideo(
                    images: loadedImages,
                    fps: fps,
                    alignEyes: shouldAlignEyes,
                    useNativeResolution: useNative,
                    onProgress: { progress in
                        Task { @MainActor [weak self] in
                            self?.exportProgress = progress
                        }
                    }
                )
            }.value

            exportedVideoURL = videoURL
            isExporting = false
            showShareSheet = true
        } catch {
            errorMessage = "Failed to create video: \(error.localizedDescription)"
            isExporting = false
            isPreparing = false
        }
    }

    private static func encodeVideo(
        images: [PlatformImage],
        fps: Int,
        alignEyes: Bool,
        useNativeResolution: Bool,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPic_\(Date().timeIntervalSince1970).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let fpsScale: Int32 = Int32(fps)

        // Determine video size from the first image
        let videoSize: CGSize
        let useHEVC: Bool
        let bitrate: Int

        if let first = images.first {
            let src = first.size
            let isLandscape = src.width > src.height
            if useNativeResolution {
                let maxDimension: CGFloat = 3840
                let longSide = max(src.width, src.height)
                let scale = longSide > maxDimension ? maxDimension / longSide : 1.0
                let w = max(2, Int(src.width * scale / 2) * 2)
                let h = max(2, Int(src.height * scale / 2) * 2)
                videoSize = CGSize(width: w, height: h)
                let pixels = w * h
                bitrate = min(max(pixels / 20, 8_000_000), 40_000_000)
                useHEVC = true
            } else {
                videoSize = isLandscape
                    ? CGSize(width: 1920, height: 1080)
                    : CGSize(width: 1080, height: 1920)
                bitrate = 8_000_000
                useHEVC = false
            }
        } else {
            videoSize = CGSize(width: 1080, height: 1920)
            bitrate = 8_000_000
            useHEVC = false
        }

        let videoWidth = Int(videoSize.width)
        let videoHeight = Int(videoSize.height)

        let videoWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let codec: AVVideoCodecType = useHEVC ? .hevc : .h264
        var compressionProps: [String: Any] = [AVVideoAverageBitRateKey: bitrate]
        if codec == .h264 {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard videoWriter.canAdd(videoWriterInput) else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }
        videoWriter.add(videoWriterInput)

        guard videoWriter.startWriting() else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot start writing"])
        }
        videoWriter.startSession(atSourceTime: .zero)

        var frameCount: Int64 = 0
        var referenceEyes: (left: CGPoint, right: CGPoint)?

        for (index, image) in images.enumerated() {
            autoreleasepool {
                let presentationTime = CMTime(value: frameCount, timescale: fpsScale)
                while !videoWriterInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                let result: CVPixelBuffer?
                if alignEyes {
                    let (buffer, refEyes) = makeAlignedPixelBuffer(
                        from: image,
                        size: videoSize,
                        referenceEyes: referenceEyes,
                        isReferenceFrame: index == 0
                    )
                    if let refEyes { referenceEyes = refEyes }
                    result = buffer
                } else {
                    result = makePixelBuffer(from: image, size: videoSize)
                }

                if let pb = result {
                    adaptor.append(pb, withPresentationTime: presentationTime)
                    frameCount += 1
                    onProgress(Double(index + 1) / Double(images.count))
                }
            }
        }

        videoWriterInput.markAsFinished()
        await videoWriter.finishWriting()

        guard videoWriter.status == .completed else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video writing failed"])
        }

        return outputURL
    }
    
    private static func makePixelBuffer(from image: PlatformImage, size: CGSize) -> CVPixelBuffer? {
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
    
    private static func makeAlignedPixelBuffer(
        from image: PlatformImage,
        size: CGSize,
        referenceEyes: (left: CGPoint, right: CGPoint)?,
        isReferenceFrame: Bool
    ) -> (CVPixelBuffer?, (left: CGPoint, right: CGPoint)?) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        let eyesResult = try? EyeDetectionService.detectEyes(in: image)
        guard let eyes = eyesResult else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        let imageAspect = imageSize.width / imageSize.height
        let videoAspect = size.width / size.height

        var drawRect: CGRect
        if imageAspect > videoAspect {
            let scaledWidth = size.height * imageAspect
            drawRect = CGRect(x: (size.width - scaledWidth) / 2, y: 0, width: scaledWidth, height: size.height)
        } else {
            let scaledHeight = size.width / imageAspect
            drawRect = CGRect(x: 0, y: (size.height - scaledHeight) / 2, width: size.width, height: scaledHeight)
        }

        if isReferenceFrame || referenceEyes == nil {
            let refLeft = CGPoint(
                x: drawRect.origin.x + (eyes.leftEye.x / imageSize.width) * drawRect.width,
                y: drawRect.origin.y + (1 - eyes.leftEye.y / imageSize.height) * drawRect.height
            )
            let refRight = CGPoint(
                x: drawRect.origin.x + (eyes.rightEye.x / imageSize.width) * drawRect.width,
                y: drawRect.origin.y + (1 - eyes.rightEye.y / imageSize.height) * drawRect.height
            )
            return (makePixelBuffer(from: image, size: size), (left: refLeft, right: refRight))
        }

        guard let ref = referenceEyes else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        let srcLeft = CGPoint(x: eyes.leftEye.x, y: imageSize.height - eyes.leftEye.y)
        let srcRight = CGPoint(x: eyes.rightEye.x, y: imageSize.height - eyes.rightEye.y)

        let srcDelta = CGPoint(x: srcRight.x - srcLeft.x, y: srcRight.y - srcLeft.y)
        let refDelta = CGPoint(x: ref.right.x - ref.left.x, y: ref.right.y - ref.left.y)

        let srcDist = hypot(srcDelta.x, srcDelta.y)
        let refDist = hypot(refDelta.x, refDelta.y)
        guard srcDist > 0.1 else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        let scale = refDist / srcDist
        let theta = atan2(refDelta.y, refDelta.x) - atan2(srcDelta.y, srcDelta.x)
        let transform = CGAffineTransform(translationX: -srcLeft.x, y: -srcLeft.y)
            .concatenating(CGAffineTransform(rotationAngle: theta))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: ref.left.x, y: ref.left.y))

        return (makePixelBufferWithTransform(from: image, size: size, imageSize: imageSize, transform: transform), nil)
    }

    private static func makePixelBufferWithTransform(
        from image: PlatformImage,
        size: CGSize,
        imageSize: CGSize,
        transform: CGAffineTransform
    ) -> CVPixelBuffer? {
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
        
        context.clear(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size))
        context.concatenate(transform)
        
        #if canImport(UIKit)
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
        }
        #elseif canImport(AppKit)
        var proposedRect = CGRect(origin: .zero, size: imageSize)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            context.draw(cgImage, in: CGRect(origin: .zero, size: imageSize))
        }
        #endif
        
        context.restoreGState()
        
        return buffer
    }
    
    func saveToFile() {
        guard let sourceURL = exportedVideoURL else { return }
        #if canImport(AppKit)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "PocketPic_Montage.mp4"
        savePanel.canCreateDirectories = true
        savePanel.title = "Save Video"
        savePanel.message = "Choose where to save your montage video"
        savePanel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destURL = savePanel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                Task { @MainActor in
                    self?.showShareSheet = false
                }
            } catch {
                Task { @MainActor in
                    self?.errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
        }
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            savePanel.begin(completionHandler: completion)
        }
        #endif
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

