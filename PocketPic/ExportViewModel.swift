//
//  ExportViewModel.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import AVFoundation
import Combine
import Photos

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import PhotosUI
#endif

private enum ExportProgressWeight {
    static let loading: Double = 0.12
    static let encoding: Double = 0.86
    static let finishing: Double = 0.02
}

@MainActor
class ExportViewModel: ObservableObject {
    @Published var isExporting = false
    @Published var exportProgress: Double = 0.0
    @Published var exportStatus: String = ""
    @Published var showShareSheet = false
    @Published var exportedVideoURL: URL?
    @Published var exportPreviewImage: PlatformImage?
    @Published var errorMessage: String?
    @Published var selectedFPS: Int = 10
    @Published var alignEyes: Bool = true
    
    let availableFPSOptions = [5, 10, 15, 24, 30, 60]

    private func setExportProgress(_ value: Double, status: String) {
        exportProgress = min(max(value, 0), 1)
        exportStatus = status
    }
    
    func exportVideo(photos: [Photo], photoStore: PhotoStore) async {
        guard !photos.isEmpty else {
            errorMessage = "No photos to export"
            return
        }

        isExporting = true
        setExportProgress(0, status: "Starting export…")

        await Task.yield()

        let fps = selectedFPS
        let shouldAlignEyes = alignEyes
        let useNative = photoStore.useNativeResolution
        let sortedPhotos = photos.sorted { $0.date < $1.date }
        let photoCount = sortedPhotos.count

        var loadedImages: [PlatformImage] = []
        loadedImages.reserveCapacity(photoCount)

        for (index, photo) in sortedPhotos.enumerated() {
            setExportProgress(
                ExportProgressWeight.loading * (Double(index) / Double(photoCount)),
                status: "Loading photo \(index + 1) of \(photoCount)"
            )
            await Task.yield()

            if let img = await photoStore.loadImageAsync(for: photo) {
                loadedImages.append(img)
            }
        }

        guard !loadedImages.isEmpty else {
            errorMessage = "Could not load any photos"
            isExporting = false
            exportStatus = ""
            return
        }

        do {
            let loadingWeight = ExportProgressWeight.loading
            let encodingWeight = ExportProgressWeight.encoding

            let tempURL = try await Task.detached(priority: .userInitiated) {
                try await ExportViewModel.encodeVideo(
                    images: loadedImages,
                    fps: fps,
                    alignEyes: shouldAlignEyes,
                    useNativeResolution: useNative,
                    onProgress: { encodeProgress, status in
                        let overall = loadingWeight + (encodeProgress * encodingWeight)
                        Task { @MainActor [weak self] in
                            self?.setExportProgress(overall, status: status)
                        }
                    }
                )
            }.value

            setExportProgress(loadingWeight + encodingWeight, status: "Saving export…")
            await Task.yield()

            let videoURL = try await Task.detached(priority: .utility) {
                try ExportViewModel.finalizeExport(at: tempURL)
            }.value

            let preview = await Task.detached(priority: .utility) {
                loadedImages.first?.normalizedUpOrientation()
            }.value
            exportPreviewImage = preview
            exportedVideoURL = videoURL
            setExportProgress(1, status: "Export complete")
            isExporting = false
            showShareSheet = true
        } catch {
            errorMessage = "Failed to create video: \(error.localizedDescription)"
            isExporting = false
            exportStatus = ""
        }
    }

    nonisolated private static func encodeVideo(
        images: [PlatformImage],
        fps: Int,
        alignEyes: Bool,
        useNativeResolution: Bool,
        onProgress: @escaping (Double, String) -> Void
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

        let imageCount = images.count
        var normalizedImages: [PlatformImage] = []
        normalizedImages.reserveCapacity(imageCount)
        for (index, image) in images.enumerated() {
            normalizedImages.append(image.normalizedUpOrientation())
            let normalizeProgress = 0.08 * Double(index + 1) / Double(imageCount)
            onProgress(normalizeProgress, "Preparing frame \(index + 1) of \(imageCount)")
        }

        var frameCount: Int64 = 0
        var referenceEyes: (left: CGPoint, right: CGPoint)?

        for (index, image) in normalizedImages.enumerated() {
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
                    let encodeProgress = 0.08 + (0.89 * Double(index + 1) / Double(imageCount))
                    onProgress(encodeProgress, "Processing frame \(index + 1) of \(imageCount)")
                }
            }
        }

        videoWriterInput.markAsFinished()
        onProgress(0.98, "Writing video…")
        await videoWriter.finishWriting()

        guard videoWriter.status == .completed else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Video writing failed"])
        }

        onProgress(1.0, "Finishing up…")
        return outputURL
    }

    nonisolated private static func finalizeExport(at tempURL: URL) throws -> URL {
        let exportsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let destURL = exportsDir.appendingPathComponent(tempURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }
    
    nonisolated private static func makePixelBuffer(from image: PlatformImage, size: CGSize) -> CVPixelBuffer? {
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
            let scaledWidth = size.height * imageAspect
            let xOffset = (size.width - scaledWidth) / 2
            drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: size.height)
        } else {
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
    
    nonisolated private static func aspectFitDrawRect(imageSize: CGSize, videoSize: CGSize) -> CGRect {
        let imageAspect = imageSize.width / imageSize.height
        let videoAspect = videoSize.width / videoSize.height
        if imageAspect > videoAspect {
            let scaledWidth = videoSize.height * imageAspect
            return CGRect(x: (videoSize.width - scaledWidth) / 2, y: 0, width: scaledWidth, height: videoSize.height)
        }
        let scaledHeight = videoSize.width / imageAspect
        return CGRect(x: 0, y: (videoSize.height - scaledHeight) / 2, width: videoSize.width, height: scaledHeight)
    }

    nonisolated private static func eyeInVideoSpace(_ point: CGPoint, imageSize: CGSize, drawRect: CGRect) -> CGPoint {
        CGPoint(
            x: drawRect.origin.x + (point.x / imageSize.width) * drawRect.width,
            y: drawRect.origin.y + (1 - point.y / imageSize.height) * drawRect.height
        )
    }

    nonisolated private static func makeAlignedPixelBuffer(
        from image: PlatformImage,
        size: CGSize,
        referenceEyes: (left: CGPoint, right: CGPoint)?,
        isReferenceFrame: Bool
    ) -> (CVPixelBuffer?, (left: CGPoint, right: CGPoint)?) {
        let eyesResult = try? EyeDetectionService.detectEyes(in: image)
        guard let eyes = eyesResult else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        let imagePixelSize = eyes.imageSize
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        let drawRect = aspectFitDrawRect(imageSize: imagePixelSize, videoSize: size)

        if isReferenceFrame || referenceEyes == nil {
            let refLeft = eyeInVideoSpace(eyes.leftEye, imageSize: imagePixelSize, drawRect: drawRect)
            let refRight = eyeInVideoSpace(eyes.rightEye, imageSize: imagePixelSize, drawRect: drawRect)
            return (makePixelBuffer(from: image, size: size), (left: refLeft, right: refRight))
        }

        guard let ref = referenceEyes else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        var srcLeft = eyeInVideoSpace(eyes.leftEye, imageSize: imagePixelSize, drawRect: drawRect)
        var srcRight = eyeInVideoSpace(eyes.rightEye, imageSize: imagePixelSize, drawRect: drawRect)

        let refDelta = CGPoint(x: ref.right.x - ref.left.x, y: ref.right.y - ref.left.y)
        var srcDelta = CGPoint(x: srcRight.x - srcLeft.x, y: srcRight.y - srcLeft.y)

        if srcDelta.x * refDelta.x + srcDelta.y * refDelta.y < 0 {
            swap(&srcLeft, &srcRight)
            srcDelta = CGPoint(x: srcRight.x - srcLeft.x, y: srcRight.y - srcLeft.y)
        }

        let srcDist = hypot(srcDelta.x, srcDelta.y)
        let refDist = hypot(refDelta.x, refDelta.y)
        guard srcDist > 0.1, refDist > 0.1 else {
            return (makePixelBuffer(from: image, size: size), nil)
        }

        var theta = atan2(refDelta.y, refDelta.x) - atan2(srcDelta.y, srcDelta.x)
        while theta > .pi { theta -= 2 * .pi }
        while theta < -.pi { theta += 2 * .pi }

        let scale = refDist / srcDist
        let alignTransform = CGAffineTransform(translationX: -srcLeft.x, y: -srcLeft.y)
            .concatenating(CGAffineTransform(rotationAngle: theta))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: ref.left.x, y: ref.left.y))

        let fitScale = drawRect.width / imagePixelSize.width
        let fitTransform = CGAffineTransform(translationX: drawRect.origin.x, y: drawRect.origin.y)
            .concatenating(CGAffineTransform(scaleX: fitScale, y: fitScale))

        return (
            makePixelBufferWithTransform(
                from: image,
                size: size,
                imagePixelSize: imagePixelSize,
                transform: alignTransform.concatenating(fitTransform)
            ),
            nil
        )
    }

    nonisolated private static func makePixelBufferWithTransform(
        from image: PlatformImage,
        size: CGSize,
        imagePixelSize: CGSize,
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
            context.draw(cgImage, in: CGRect(origin: .zero, size: imagePixelSize))
        }
        #elseif canImport(AppKit)
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cgImage, in: CGRect(origin: .zero, size: imagePixelSize))
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
    
    func saveToPhotos(videoURL: URL, albumName: String) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)

        guard status == .authorized || status == .limited else {
            errorMessage = "Photo library access denied"
            return
        }

        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            errorMessage = "Exported video file is no longer available"
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let assetRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL) else {
                    return
                }

                let albumFetchOptions = PHFetchOptions()
                albumFetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
                let albumFetchResult = PHAssetCollection.fetchAssetCollections(
                    with: .album,
                    subtype: .any,
                    options: albumFetchOptions
                )

                if let album = albumFetchResult.firstObject,
                   let albumChangeRequest = PHAssetCollectionChangeRequest(for: album),
                   let placeholder = assetRequest.placeholderForCreatedAsset {
                    albumChangeRequest.addAssets([placeholder] as NSArray)
                } else if let placeholder = assetRequest.placeholderForCreatedAsset {
                    let albumChangeRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    albumChangeRequest.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            errorMessage = "Failed to save to Photos: \(error.localizedDescription)"
        }
    }
}

