//
//  ExportFrameLoader.swift
//  PocketPic
//
//  Loads one export frame at a time with bounded memory (ImageIO downsample).
//

import Foundation
import ImageIO
import Photos

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ExportFrameRef: Sendable {
    let localURL: URL?
    let photosLibraryIdentifier: String
}

enum ExportFrameLoader {
    nonisolated static func pixelSize(for ref: ExportFrameRef) -> CGSize? {
        if let localURL = ref.localURL, let size = pixelSizeAtFileURL(localURL) {
            return size
        }
        return photosAssetPixelSize(identifier: ref.photosLibraryIdentifier)
    }

    nonisolated static func maxDecodePixelDimension(videoSize: CGSize, useNativeResolution: Bool) -> CGFloat {
        let longSide = max(videoSize.width, videoSize.height)
        if useNativeResolution {
            return min(3840, max(longSide, 1920))
        }
        return max(longSide, 1080)
    }

    nonisolated static func loadFrame(
        _ ref: ExportFrameRef,
        maxPixelDimension: CGFloat
    ) async -> PlatformImage? {
        let capped = max(64, maxPixelDimension)
        if let localURL = ref.localURL {
            return downsampleImage(at: localURL, maxPixelDimension: capped)
        }
        return await loadFromPhotosLibrary(identifier: ref.photosLibraryIdentifier, maxPixelDimension: capped)
    }

    nonisolated private static func pixelSizeAtFileURL(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func photosAssetPixelSize(identifier: String) -> CGSize? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        return CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    }

    nonisolated private static func downsampleImage(at url: URL, maxPixelDimension: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension as NSNumber
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return nil
        #endif
    }

    nonisolated private static func loadFromPhotosLibrary(
        identifier: String,
        maxPixelDimension: CGFloat
    ) async -> PlatformImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard !didResume else { return }
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    didResume = true
                    continuation.resume(returning: nil)
                    return
                }
                didResume = true
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: downsampleImage(from: data, maxPixelDimension: maxPixelDimension))
            }
        }
    }

    nonisolated private static func downsampleImage(from data: Data, maxPixelDimension: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelDimension) as NSNumber
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return nil
        #endif
    }
}
