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

private enum ExportProgressPhase {
    static let prepareEnd = 0.05
    static let framesEnd = 0.97
    static let writeEnd = 0.99
}

private struct EyeReferenceInVideo {
    let left: CGPoint
    let right: CGPoint
}

struct ExportCompletion: Identifiable {
    let id = UUID()
    let videoURL: URL
}

@MainActor
class ExportViewModel: ObservableObject {
    @Published var isExporting = false
    @Published var exportProgress: Double = 0.0
    @Published var exportStatus: String = ""
    @Published var completedExport: ExportCompletion?
    @Published var exportedVideoURL: URL?
    @Published var exportPreviewImage: PlatformImage?
    @Published var errorMessage: String?
    @Published var selectedFPS: Int = 10
    @Published var alignEyes: Bool = true
    
    let availableFPSOptions = [5, 10, 15, 24, 30, 60]

    private func setExportProgress(_ value: Double, status: String) {
        let clamped = min(max(value, 0), 1)
        if clamped >= exportProgress {
            exportProgress = clamped
        }
        exportStatus = status
    }

    func exportVideo(photos: [Photo], photoStore: PhotoStore) async {
        guard !photos.isEmpty else {
            errorMessage = "No photos to export"
            return
        }

        isExporting = true
        completedExport = nil
        exportedVideoURL = nil
        exportPreviewImage = nil
        exportProgress = 0
        setExportProgress(0.02, status: "Starting export…")

        await Task.yield()

        let fps = selectedFPS
        let shouldAlignEyes = alignEyes
        let useNative = photoStore.useNativeResolution
        let sortedPhotos = photos.sorted { $0.date < $1.date }

        let frameRefs: [ExportFrameRef] = sortedPhotos.map { photo in
            let localURL = photoStore.getPhotoURL(for: photo)
            let hasLocalFile = FileManager.default.fileExists(atPath: localURL.path)
            return ExportFrameRef(
                localURL: hasLocalFile ? localURL : nil,
                photosLibraryIdentifier: photo.filename
            )
        }

        guard frameRefs.contains(where: { $0.localURL != nil || !$0.photosLibraryIdentifier.isEmpty }) else {
            errorMessage = "Could not load any photos"
            isExporting = false
            exportStatus = ""
            return
        }

        if let firstRef = frameRefs.first,
           let preview = await ExportFrameLoader.loadFrame(firstRef, maxPixelDimension: 480) {
            exportPreviewImage = preview
        }

        do {
            let progressHandler: @Sendable (Double, String) -> Void = { [weak self] progress, status in
                DispatchQueue.main.async {
                    self?.setExportProgress(progress, status: status)
                }
            }

            let tempURL = try await Task.detached(priority: .userInitiated) {
                try await ExportViewModel.encodeVideo(
                    frameRefs: frameRefs,
                    fps: fps,
                    alignEyes: shouldAlignEyes,
                    useNativeResolution: useNative,
                    onProgress: progressHandler
                )
            }.value

            setExportProgress(0.98, status: "Saving export…")
            await Task.yield()

            let videoURL = try await Task.detached(priority: .utility) {
                try ExportViewModel.finalizeExport(at: tempURL)
            }.value

            exportedVideoURL = videoURL
            setExportProgress(1, status: "Export complete")
            isExporting = false
        } catch {
            errorMessage = "Failed to create video: \(error.localizedDescription)"
            isExporting = false
            exportStatus = ""
        }
    }

    nonisolated private static func encodeVideo(
        frameRefs: [ExportFrameRef],
        fps: Int,
        alignEyes: Bool,
        useNativeResolution: Bool,
        onProgress: @escaping (Double, String) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketPic_\(Date().timeIntervalSince1970).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let fpsScale: Int32 = Int32(fps)

        let imageCount = frameRefs.count
        guard imageCount > 0 else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "No frames to export"])
        }

        onProgress(0.02, "Analyzing photos…")
        let pixelSizes = frameRefs.compactMap { ExportFrameLoader.pixelSize(for: $0) }
        let (videoSize, useHEVC, bitrate) = computeVideoSize(
            from: pixelSizes,
            useNativeResolution: useNativeResolution
        )
        let maxDecodePixel = ExportFrameLoader.maxDecodePixelDimension(
            videoSize: videoSize,
            useNativeResolution: useNativeResolution
        )
        onProgress(ExportProgressPhase.prepareEnd, "Preparing video…")

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

        let referenceEyes: EyeReferenceInVideo? = alignEyes
            ? await referenceEyesFromFirstPhoto(
                firstRef: frameRefs[0],
                videoSize: videoSize,
                maxDecodePixel: maxDecodePixel
            )
            : nil

        let frameSpan = ExportProgressPhase.framesEnd - ExportProgressPhase.prepareEnd
        var frameCount: Int64 = 0

        for (index, ref) in frameRefs.enumerated() {
            let slotMid = ExportProgressPhase.prepareEnd
                + frameSpan * (Double(index) + 0.25) / Double(imageCount)
            let slotEnd = ExportProgressPhase.prepareEnd
                + frameSpan * Double(index + 1) / Double(imageCount)

            onProgress(slotMid, "Loading frame \(index + 1) of \(imageCount)")

            guard let image = await ExportFrameLoader.loadFrame(ref, maxPixelDimension: maxDecodePixel) else {
                onProgress(slotEnd, "Skipped frame \(index + 1) of \(imageCount)")
                continue
            }
            let normalized = exportReadyImage(image)

            autoreleasepool {
                let presentationTime = CMTime(value: frameCount, timescale: fpsScale)
                while !videoWriterInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                let result: CVPixelBuffer?
                if alignEyes {
                    result = makeAlignedPixelBuffer(
                        from: normalized,
                        size: videoSize,
                        referenceEyes: referenceEyes
                    )
                } else {
                    result = makePixelBuffer(from: normalized, size: videoSize)
                }

                if let pb = result {
                    adaptor.append(pb, withPresentationTime: presentationTime)
                    frameCount += 1
                }
            }

            onProgress(slotEnd, "Processing frame \(index + 1) of \(imageCount)")
        }

        guard frameCount > 0 else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not encode any frames"])
        }

        videoWriterInput.markAsFinished()
        onProgress(ExportProgressPhase.writeEnd, "Writing video…")
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
    
    nonisolated private static func computeVideoSize(
        from pixelSizes: [CGSize],
        useNativeResolution: Bool
    ) -> (size: CGSize, useHEVC: Bool, bitrate: Int) {
        guard let largest = pixelSizes.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return (CGSize(width: 1080, height: 1920), false, 8_000_000)
        }

        let hasLandscape = pixelSizes.contains { $0.width > $0.height }
        let hasPortrait = pixelSizes.contains { $0.width <= $0.height }
        let mixedOrientations = hasLandscape && hasPortrait

        if useNativeResolution {
            let maxDimension: CGFloat = 3840
            var src = largest
            if mixedOrientations, src.width < src.height {
                src = CGSize(width: src.height, height: src.width)
            }
            let longSide = max(src.width, src.height)
            let scale = longSide > maxDimension ? maxDimension / longSide : 1.0
            let w = max(2, Int(src.width * scale / 2) * 2)
            let h = max(2, Int(src.height * scale / 2) * 2)
            let pixels = w * h
            return (
                CGSize(width: w, height: h),
                true,
                min(max(pixels / 20, 8_000_000), 40_000_000)
            )
        }

        if mixedOrientations || (hasLandscape && !hasPortrait) {
            return (CGSize(width: 1920, height: 1080), false, 8_000_000)
        }
        return (CGSize(width: 1080, height: 1920), false, 8_000_000)
    }

    nonisolated private static func exportReadyImage(_ image: PlatformImage) -> PlatformImage {
        image.normalizedUpOrientation()
    }

    nonisolated private static func canonicalPixelSize(for image: PlatformImage) -> CGSize? {
        let ready = exportReadyImage(image)
        #if canImport(UIKit)
        guard let cgImage = ready.cgImage else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
        #elseif canImport(AppKit)
        guard let cgImage = ready.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
        #endif
    }

    nonisolated private static func mapEyePointToRect(
        _ point: CGPoint,
        imageSize: CGSize,
        drawRect: CGRect
    ) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return point }
        return CGPoint(
            x: drawRect.minX + (point.x / imageSize.width) * drawRect.width,
            y: drawRect.minY + (point.y / imageSize.height) * drawRect.height
        )
    }

    /// Eye positions from the first photo in video space — used as the scale/position target for all frames.
    nonisolated private static func referenceEyesFromFirstPhoto(
        firstRef: ExportFrameRef,
        videoSize: CGSize,
        maxDecodePixel: CGFloat
    ) async -> EyeReferenceInVideo? {
        guard let image = await ExportFrameLoader.loadFrame(firstRef, maxPixelDimension: maxDecodePixel) else {
            return nil
        }
        return eyeReferenceInVideo(for: exportReadyImage(image), videoSize: videoSize)
    }

    nonisolated private static func eyeReferenceInVideo(
        for normalized: PlatformImage,
        videoSize: CGSize
    ) -> EyeReferenceInVideo? {
        guard let eyes = try? EyeDetectionService.detectEyes(in: normalized),
              let imagePixelSize = canonicalPixelSize(for: normalized),
              eyes.imageSize.width > 0,
              eyes.imageSize.height > 0 else {
            return nil
        }

        let fitted = aspectFitDrawRectTopLeft(imagePixelSize: imagePixelSize, videoSize: videoSize)
        let left = mapEyePointToRect(eyes.leftEye, imageSize: eyes.imageSize, drawRect: fitted)
        let right = mapEyePointToRect(eyes.rightEye, imageSize: eyes.imageSize, drawRect: fitted)
        return EyeReferenceInVideo(left: left, right: right)
    }

    nonisolated private static func eyesInVideoSpace(
        for normalized: PlatformImage,
        videoSize: CGSize
    ) -> (left: CGPoint, right: CGPoint, fitted: CGRect)? {
        guard let eyes = try? EyeDetectionService.detectEyes(in: normalized),
              let imagePixelSize = canonicalPixelSize(for: normalized) else {
            return nil
        }
        let fitted = aspectFitDrawRectTopLeft(imagePixelSize: imagePixelSize, videoSize: videoSize)
        let left = mapEyePointToRect(eyes.leftEye, imageSize: eyes.imageSize, drawRect: fitted)
        let right = mapEyePointToRect(eyes.rightEye, imageSize: eyes.imageSize, drawRect: fitted)
        return (left, right, fitted)
    }

    nonisolated private static func aspectFitDrawRectTopLeft(
        imagePixelSize: CGSize,
        videoSize: CGSize
    ) -> CGRect {
        AVMakeRect(
            aspectRatio: imagePixelSize,
            insideRect: CGRect(origin: .zero, size: videoSize)
        )
    }

    nonisolated private static func makePixelBuffer(from image: PlatformImage, size: CGSize) -> CVPixelBuffer? {
        let normalized = exportReadyImage(image)
        guard let imagePixelSize = canonicalPixelSize(for: normalized) else { return nil }
        let fitted = aspectFitDrawRectTopLeft(imagePixelSize: imagePixelSize, videoSize: size)
        return renderFrameImage(normalized, videoSize: size, drawImage: { context, _ in
            drawPlatformImage(normalized, in: fitted, context: context)
        })
    }

    nonisolated private static func makeAlignedPixelBuffer(
        from image: PlatformImage,
        size: CGSize,
        referenceEyes: EyeReferenceInVideo?
    ) -> CVPixelBuffer? {
        let normalized = exportReadyImage(image)
        guard let referenceEyes,
              let detected = eyesInVideoSpace(for: normalized, videoSize: size) else {
            return makePixelBuffer(from: normalized, size: size)
        }

        let warpTransform = similarityTransform(
            from: detected.left,
            detected.right,
            to: referenceEyes.left,
            referenceEyes.right
        )

        return renderFrameImage(normalized, videoSize: size) { context, videoSize in
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: videoSize))
            context.concatenate(warpTransform)
            drawPlatformImage(normalized, in: detected.fitted, context: context)
            context.restoreGState()
        }
    }

    #if canImport(UIKit)
    nonisolated private static func renderFrameImage(
        _ image: UIImage,
        videoSize: CGSize,
        drawImage: (CGContext, CGSize) -> Void
    ) -> CVPixelBuffer? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: videoSize, format: format)
        let frameImage = renderer.image { rendererContext in
            UIColor.black.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: videoSize))
            drawImage(rendererContext.cgContext, videoSize)
        }
        guard let cgImage = frameImage.cgImage else { return nil }
        return copyCGImageIntoPixelBuffer(cgImage, videoSize: videoSize)
    }

    nonisolated private static func drawPlatformImage(_ image: UIImage, in rect: CGRect, context: CGContext) {
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        UIGraphicsPopContext()
    }
    #elseif canImport(AppKit)
    nonisolated private static func renderFrameImage(
        _ image: NSImage,
        videoSize: CGSize,
        drawImage: (CGContext, CGSize) -> Void
    ) -> CVPixelBuffer? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(videoSize.width),
            pixelsHigh: Int(videoSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: videoSize))
        drawImage(context, videoSize)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage else { return nil }
        return copyCGImageIntoPixelBuffer(cgImage, videoSize: videoSize)
    }

    nonisolated private static func drawPlatformImage(_ image: NSImage, in rect: CGRect, context: CGContext) {
        _ = context
        image.draw(in: rect)
    }
    #endif

    nonisolated private static func similarityTransform(
        from sourceLeft: CGPoint,
        _ sourceRight: CGPoint,
        to targetLeft: CGPoint,
        _ targetRight: CGPoint
    ) -> CGAffineTransform {
        var srcLeft = sourceLeft
        var srcRight = sourceRight
        let targetDelta = CGPoint(x: targetRight.x - targetLeft.x, y: targetRight.y - targetLeft.y)
        var sourceDelta = CGPoint(x: srcRight.x - srcLeft.x, y: srcRight.y - srcLeft.y)

        if sourceDelta.x * targetDelta.x + sourceDelta.y * targetDelta.y < 0 {
            swap(&srcLeft, &srcRight)
            sourceDelta = CGPoint(x: srcRight.x - srcLeft.x, y: srcRight.y - srcLeft.y)
        }

        let sourceDistance = hypot(sourceDelta.x, sourceDelta.y)
        let targetDistance = hypot(targetDelta.x, targetDelta.y)
        guard sourceDistance > 0.1, targetDistance > 0.1 else {
            return .identity
        }

        var theta = atan2(targetDelta.y, targetDelta.x) - atan2(sourceDelta.y, sourceDelta.x)
        while theta > .pi { theta -= 2 * .pi }
        while theta < -.pi { theta += 2 * .pi }

        let scale = targetDistance / sourceDistance
        return CGAffineTransform(translationX: -srcLeft.x, y: -srcLeft.y)
            .concatenating(CGAffineTransform(rotationAngle: theta))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: targetLeft.x, y: targetLeft.y))
    }


    nonisolated private static func copyCGImageIntoPixelBuffer(
        _ cgImage: CGImage,
        videoSize: CGSize
    ) -> CVPixelBuffer? {
        drawIntoPixelBuffer(videoSize: videoSize) { context in
            #if canImport(UIKit)
            // UIGraphicsImageRenderer output is already top-left; AVFoundation expects that layout.
            context.draw(cgImage, in: CGRect(origin: .zero, size: videoSize))
            #else
            context.translateBy(x: 0, y: videoSize.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(origin: .zero, size: videoSize))
            #endif
        }
    }

    nonisolated private static func drawIntoPixelBuffer(
        videoSize: CGSize,
        draw: (CGContext) -> Void
    ) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(videoSize.width),
            Int(videoSize.height),
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
            width: Int(videoSize.width),
            height: Int(videoSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: videoSize))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: videoSize))

        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: videoSize))
        draw(context)
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
                    self?.completedExport = nil
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
                guard PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL) != nil else {
                    return
                }
            }
        } catch {
            errorMessage = "Failed to save to Photos: \(error.localizedDescription)"
        }
    }
}

