//
//  EyeDetectionService.swift
//  PocketPic
//
//  Uses Apple's Vision framework to detect eye locations on a selfie image.
//

import Vision
import Foundation
import simd

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct EyeLocations {
    let leftEye: CGPoint
    let rightEye: CGPoint
    let imageSize: CGSize
}

enum EyeDetectionError: Error, LocalizedError {
    case noFaceDetected
    case missingEyeLandmarks
    case imageConversionFailed
    
    var errorDescription: String? {
        switch self {
        case .noFaceDetected: return "No face detected in image"
        case .missingEyeLandmarks: return "Could not detect eye landmarks"
        case .imageConversionFailed: return "Failed to process image"
        }
    }
}

enum EyeDetectionService {
    
    static func detectEyes(in image: PlatformImage) throws -> EyeLocations {
        let (cgImage, orientation) = try makeCGImageAndOrientation(from: image)
        let (imageWidth, imageHeight) = imageDimensions(for: cgImage, orientation: orientation)
        
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        
        try handler.perform([request])
        
        guard let observation = request.results?.first else {
            throw EyeDetectionError.noFaceDetected
        }
        
        guard let landmarks = observation.landmarks else {
            throw EyeDetectionError.missingEyeLandmarks
        }
        
        let leftEyePoint = try centerPoint(
            for: landmarks.leftEye,
            faceBoundingBox: observation.boundingBox,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let rightEyePoint = try centerPoint(
            for: landmarks.rightEye,
            faceBoundingBox: observation.boundingBox,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        
        return EyeLocations(
            leftEye: leftEyePoint,
            rightEye: rightEyePoint,
            imageSize: CGSize(width: imageWidth, height: imageHeight)
        )
    }
    
    private static func imageDimensions(for cgImage: CGImage, orientation: CGImagePropertyOrientation) -> (CGFloat, CGFloat) {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return (h, w)
        default:
            return (w, h)
        }
    }
    
    private static func makeCGImageAndOrientation(from image: PlatformImage) throws -> (CGImage, CGImagePropertyOrientation) {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else {
            throw EyeDetectionError.imageConversionFailed
        }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return (cgImage, orientation)
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw EyeDetectionError.imageConversionFailed
        }
        return (cgImage, .up)
        #endif
    }
    
    private static func centerPoint(
        for region: VNFaceLandmarkRegion2D?,
        faceBoundingBox: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) throws -> CGPoint {
        guard let region = region, !region.normalizedPoints.isEmpty else {
            throw EyeDetectionError.missingEyeLandmarks
        }
        
        let points = region.normalizedPoints
        let sumX = points.reduce(0.0) { $0 + Double($1.x) }
        let sumY = points.reduce(0.0) { $0 + Double($1.y) }
        let count = Double(points.count)
        let normalizedInFace = vector_float2(Float(sumX / count), Float(sumY / count))
        
        let pixelPoint = VNImagePointForFaceLandmarkPoint(
            normalizedInFace,
            faceBoundingBox,
            Int(imageWidth),
            Int(imageHeight)
        )
        
        return CGPoint(
            x: pixelPoint.x,
            y: imageHeight - pixelPoint.y
        )
    }
}

#if canImport(UIKit)
private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
