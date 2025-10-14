//
//  PlatformCompat.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/14/25.
//

import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage

extension UIImage {
    func fixedOrientation() -> UIImage {
        // No-op if the orientation is already correct
        if imageOrientation == .up {
            return self
        }
        
        // We need to calculate the proper transformation to make the image upright.
        var transform = CGAffineTransform.identity
        
        switch imageOrientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: size.width, y: size.height)
            transform = transform.rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: size.width, y: 0)
            transform = transform.rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: size.height)
            transform = transform.rotated(by: -.pi / 2)
        case .up, .upMirrored:
            break
        @unknown default:
            break
        }
        
        switch imageOrientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: size.width, y: 0)
            transform = transform.scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: size.height, y: 0)
            transform = transform.scaledBy(x: -1, y: 1)
        case .up, .down, .left, .right:
            break
        @unknown default:
            break
        }
        
        // Now we draw the underlying CGImage into a new context, applying the transform
        // calculated above.
        guard let cgImage = self.cgImage,
              let colorSpace = cgImage.colorSpace,
              let context = CGContext(data: nil,
                                    width: Int(size.width),
                                    height: Int(size.height),
                                    bitsPerComponent: cgImage.bitsPerComponent,
                                    bytesPerRow: 0,
                                    space: colorSpace,
                                    bitmapInfo: cgImage.bitmapInfo.rawValue) else {
            return self
        }
        
        context.concatenate(transform)
        
        switch imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.height, height: size.width))
        default:
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        
        // And now we just create a new UIImage from the drawing context
        guard let newCGImage = context.makeImage() else {
            return self
        }
        
        return UIImage(cgImage: newCGImage)
    }
}

#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    var pngData: Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
    
    var jpegData: ((CGFloat) -> Data?)? {
        return { quality in
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
    }
}
#endif

