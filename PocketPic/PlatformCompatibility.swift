//
//  PlatformCompatibility.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage

extension UIImage {
    /// Renders the image upright so pixel data matches `size` and Vision/drawing agree.
    nonisolated func normalizedUpOrientation() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    nonisolated var pixelSize: CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    nonisolated func pocketPicExportPreviewThumbnail(maxPixelDimension: CGFloat = 480) -> UIImage {
        let pixel = pixelSize
        guard pixel.width > 0, pixel.height > 0 else { return self }
        let fit = min(maxPixelDimension / pixel.width, maxPixelDimension / pixel.height, 1)
        guard fit < 1 else { return normalizedUpOrientation() }
        let thumbSize = CGSize(width: pixel.width * fit, height: pixel.height * fit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: thumbSize, format: format)
        return renderer.image { _ in
            normalizedUpOrientation().draw(in: CGRect(origin: .zero, size: thumbSize))
        }
    }
}
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    /// Renders the image upright so pixel data matches `size` and Vision/drawing agree.
    nonisolated func normalizedUpOrientation() -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let pixelSize = NSSize(width: cgImage.width, height: cgImage.height)
        guard let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return self }
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let normalizedCGImage = {
            context.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))
            return context.makeImage()
        }() else {
            return self
        }
        return NSImage(cgImage: normalizedCGImage, size: pixelSize)
    }

    nonisolated func pocketPicExportPreviewThumbnail(maxPixelDimension: CGFloat = 480) -> NSImage {
        let normalized = normalizedUpOrientation()
        let pixel = normalized.pixelSize
        guard pixel.width > 0, pixel.height > 0 else { return normalized }
        let fit = min(maxPixelDimension / pixel.width, maxPixelDimension / pixel.height, 1)
        guard fit < 1 else { return normalized }
        let thumbSize = NSSize(width: pixel.width * fit, height: pixel.height * fit)
        let thumbnail = NSImage(size: thumbSize)
        thumbnail.lockFocus()
        normalized.draw(in: NSRect(origin: .zero, size: thumbSize))
        thumbnail.unlockFocus()
        return thumbnail
    }

    nonisolated var pixelSize: CGSize {
        if let rep = representations.first as? NSBitmapImageRep {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return size
    }
}
#endif

// MARK: - Shared Colors

extension Color {
    /// Primary tint used throughout the app.
    static var appAccent: Color { Color(red: 0.051, green: 0.580, blue: 0.533) }

    static var systemBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.clear
        #endif
    }

    static var systemGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }
}

// MARK: - iOS layout

#if canImport(UIKit)
private struct RequestCameraKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    var requestCamera: Binding<Bool> {
        get { self[RequestCameraKey.self] }
        set { self[RequestCameraKey.self] = newValue }
    }
}
#endif

extension View {
    /// Centers primary content on iPad while using full width on iPhone.
    @ViewBuilder
    func pocketPicReadableWidth() -> some View {
        modifier(PocketPicReadableWidthModifier())
    }
}

private struct PocketPicReadableWidthModifier: ViewModifier {
    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Modal presentation

enum PocketPicModalSize {
    case export
    case exportComplete
    case eyeDetection
    case albumPicker
    case photoDetail

    var width: CGFloat {
        switch self {
        case .export: 440
        case .exportComplete: 420
        case .eyeDetection: 580
        case .albumPicker: 380
        case .photoDetail: 760
        }
    }

    var height: CGFloat {
        switch self {
        case .export: 520
        case .exportComplete: 540
        case .eyeDetection: 640
        case .albumPicker: 480
        case .photoDetail: 680
        }
    }
}

extension View {
    @ViewBuilder
    func pocketPicModalPresentation(_ size: PocketPicModalSize) -> some View {
        #if os(macOS)
        frame(width: size.width, height: size.height)
            .presentationSizing(.fitted)
        #elseif canImport(UIKit)
        switch size {
        case .export:
            presentationDetents([.large])
        case .exportComplete:
            presentationDetents([.large])
        case .eyeDetection:
            presentationDetents([.large])
        case .albumPicker:
            presentationDetents([.medium, .large])
        case .photoDetail:
            presentationDetents([.large])
        }
        presentationDragIndicator(.visible)
        if size != .export {
            presentationBackground(Color.systemGroupedBackground)
        }
        #else
        self
        #endif
    }
}

struct PocketPicSectionCard<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(
        _ title: String,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.systemBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            footer()
        }
    }
}
