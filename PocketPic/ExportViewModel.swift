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
        exportProgress = min(max(value, 0), 1)
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
        setExportProgress(0, status: "Starting export…")

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
            let loadingWeight = ExportProgressWeight.loading
            let encodingWeight = ExportProgressWeight.encoding

            let tempURL = try await Task.detached(priority: .userInitiated) {
                try await ExportViewModel.encodeVideo(
                    frameRefs: frameRefs,
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

        onProgress(0.04, "Analyzing photos…")
        let pixelSizes = frameRefs.compactMap { ExportFrameLoader.pixelSize(for: $0) }
        let (videoSize, useHEVC, bitrate) = computeVideoSize(
            from: pixelSizes,
            useNativeResolution: useNativeResolution
        )
        let maxDecodePixel = ExportFrameLoader.maxDecodePixelDimension(
            videoSize: videoSize,
            useNativeResolution: useNativeResolution
        )
        onProgress(0.08, "Preparing video…")

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
            ? await canonicalEyeTargetsInVideo(
                videoSize: videoSize,
                frameRefs: frameRefs,
                useNativeResolution: useNativeResolution
            )
            : nil

        var frameCount: Int64 = 0

        for (index, ref) in frameRefs.enumerated() {
            let loadProgress = 0.08 + (0.12 * Double(index) / Double(imageCount))
            onProgress(loadProgress, "Loading frame \(index + 1) of \(imageCount)")

            guard let image = await ExportFrameLoader.loadFrame(ref, maxPixelDimension: maxDecodePixel) else {
                continue
            }

            autoreleasepool {
                let presentationTime = CMTime(value: frameCount, timescale: fpsScale)
                while !videoWriterInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.01)
                }

                let result: CVPixelBuffer?
                if alignEyes {
                    result = makeAlignedPixelBuffer(
                        from: image,
                        size: videoSize,
                        referenceEyes: referenceEyes
                    )
                } else {
                    result = makePixelBuffer(from: image, size: videoSize)
                }

                if let pb = result {
                    adaptor.append(pb, withPresentationTime: presentationTime)
                    frameCount += 1
                    let encodeProgress = 0.2 + (0.77 * Double(frameCount) / Double(imageCount))
                    onProgress(encodeProgress, "Processing frame \(frameCount) of \(imageCount)")
                }
            }
        }

        guard frameCount > 0 else {
            throw NSError(domain: "PocketPic", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not encode any frames"])
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

    nonisolated private static func canonicalPixelSize(for image: PlatformImage) -> CGSize? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CGSize(width: cgImage.width, height: cgImage.height)
        #endif
    }

    /// Fixed eye positions in the output frame (UIKit top-left coordinates).
    nonisolated private static func canonicalEyeTargetsInVideo(
        videoSize: CGSize,
        frameRefs: [ExportFrameRef],
        useNativeResolution: Bool
    ) async -> EyeReferenceInVideo? {
        let landscape = frameRefs.filter { ref in
            guard let size = ExportFrameLoader.pixelSize(for: ref) else { return false }
            return size.width > size.height
        }
        let candidates = landscape.isEmpty ? frameRefs : landscape

        let midX = videoSize.width * 0.5
        var midY = videoSize.height * 0.36
        var spacing = videoSize.width * 0.22

        let eyeScanMax = ExportFrameLoader.maxDecodePixelDimension(
            videoSize: videoSize,
            useNativeResolution: useNativeResolution
        )

        for ref in candidates {
            guard let image = await ExportFrameLoader.loadFrame(ref, maxPixelDimension: eyeScanMax),
                  let eyes = try? EyeDetectionService.detectEyes(in: image),
                  eyes.imageSize.width > 0,
                  eyes.imageSize.height > 0 else {
                continue
            }
            let orientedSize = eyes.imageSize
            let left = eyes.leftEye
            let right = eyes.rightEye
            let eyeMid = CGPoint(x: (left.x + right.x) * 0.5, y: (left.y + right.y) * 0.5)
            midY = (eyeMid.y / orientedSize.height) * videoSize.height
            let imageSpacing = hypot(right.x - left.x, right.y - left.y)
            if imageSpacing > 1 {
                spacing = videoSize.width * (imageSpacing / orientedSize.width)
            }
            break
        }

        return EyeReferenceInVideo(
            left: CGPoint(x: midX - spacing * 0.5, y: midY),
            right: CGPoint(x: midX + spacing * 0.5, y: midY)
        )
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
        guard let imagePixelSize = canonicalPixelSize(for: image) else { return nil }
        let fitted = aspectFitDrawRectTopLeft(imagePixelSize: imagePixelSize, videoSize: size)
        return renderFrameImage(image, videoSize: size, drawImage: { context, _ in
            drawPlatformImage(image, in: fitted, context: context)
        })
    }

    nonisolated private static func makeAlignedPixelBuffer(
        from image: PlatformImage,
        size: CGSize,
        referenceEyes: EyeReferenceInVideo?
    ) -> CVPixelBuffer? {
        guard let imagePixelSize = canonicalPixelSize(for: image) else {
            return makePixelBuffer(from: image, size: size)
        }

        guard let referenceEyes,
              let eyes = try? EyeDetectionService.detectEyes(in: image) else {
            return makePixelBuffer(from: image, size: size)
        }

        let drawSize = eyes.imageSize
        let warpTransform = similarityTransform(
            from: eyes.leftEye,
            eyes.rightEye,
            to: referenceEyes.left,
            referenceEyes.right
        )

        return renderFrameImage(image, videoSize: size) { context, videoSize in
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: videoSize))
            context.concatenate(warpTransform)
            drawPlatformImage(image, in: CGRect(origin: .zero, size: drawSize), context: context)
            context.restoreGState()
        }
    }

    #if canImport(UIKit)
    nonisolated private static func renderTopLeftCGImage(
        videoSize: CGSize,
        drawImage: (CGContext, CGSize) -> Void
    ) -> CGImage? {
        let width = Int(videoSize.width)
        let height = Int(videoSize.height)
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: videoSize))

        context.saveGState()
        context.translateBy(x: 0, y: videoSize.height)
        context.scaleBy(x: 1, y: -1)
        drawImage(context, videoSize)
        context.restoreGState()

        return context.makeImage()
    }

    nonisolated private static func renderFrameImage(
        _ image: UIImage,
        videoSize: CGSize,
        drawImage: (CGContext, CGSize) -> Void
    ) -> CVPixelBuffer? {
        guard let frameImage = renderTopLeftCGImage(videoSize: videoSize, drawImage: drawImage) else {
            return nil
        }
        return drawIntoPixelBuffer(videoSize: videoSize) { bufferContext in
            bufferContext.translateBy(x: 0, y: videoSize.height)
            bufferContext.scaleBy(x: 1, y: -1)
            bufferContext.draw(frameImage, in: CGRect(origin: .zero, size: videoSize))
        }
    }

    nonisolated private static func drawPlatformImage(_ image: UIImage, in rect: CGRect, context: CGContext) {
        guard let cgImage = image.cgImage else { return }
        context.draw(cgImage, in: rect)
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
        return drawIntoPixelBuffer(videoSize: videoSize) { bufferContext in
            bufferContext.translateBy(x: 0, y: videoSize.height)
            bufferContext.scaleBy(x: 1, y: -1)
            bufferContext.draw(cgImage, in: CGRect(origin: .zero, size: videoSize))
        }
    }

    nonisolated private static func drawPlatformImage(_ image: NSImage, in rect: CGRect, context: CGContext) {
        _ = context
        image.draw(in: rect)
    }
    #endif

    nonisolated private static func scaledEyePoint(
        _ point: CGPoint,
        from sourceSize: CGSize,
        to targetSize: CGSize
    ) -> CGPoint {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return point }
        guard sourceSize != targetSize else { return point }
        return CGPoint(
            x: point.x * targetSize.width / sourceSize.width,
            y: point.y * targetSize.height / sourceSize.height
        )
    }

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

