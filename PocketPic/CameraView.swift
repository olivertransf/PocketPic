//
//  CameraView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI
import AVFoundation
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CameraView: View {
    @EnvironmentObject var photoStore: PhotoStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cameraController = CameraController()
    @State private var capturedImage: PlatformImage?
    @State private var showCapturedImage = false
    @State private var showOverlay = false
    let onDismiss: (() -> Void)?
    
    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        CameraViewWrapper(
            cameraController: cameraController,
            capturedImage: $capturedImage,
            showCapturedImage: $showCapturedImage,
            showOverlay: $showOverlay,
            lastPhotoImage: getLastPhotoImage(),
            overlayOpacity: photoStore.overlayOpacity,
            onDismiss: { onDismiss?() ?? dismiss() },
            onCapture: capturePhoto,
            onSave: savePhoto
        )
        .ignoresSafeArea()
        #if canImport(UIKit)
        .statusBarHidden()
        #endif
        .onAppear {
            cameraController.startSession()
        }
        .onDisappear {
            cameraController.stopSession()
        }
    }
    
    private func getLastPhotoImage() -> PlatformImage? {
        guard let lastPhoto = photoStore.getLastPhoto() else { return nil }
        return photoStore.loadImage(for: lastPhoto)
    }
    
    private func capturePhoto() {
        cameraController.capturePhoto { image in
            withAnimation {
                capturedImage = image
                showCapturedImage = true
            }
        }
    }
    
    private func savePhoto() {
        if let image = capturedImage {
            photoStore.savePhoto(image)
            dismiss()
        }
    }
}

// MARK: - Camera Controller

class CameraController: NSObject, ObservableObject {
    let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var captureCompletion: ((PlatformImage?) -> Void)?
    private var isSetup = false
    var deviceInput: AVCaptureDeviceInput?
    
    override init() {
        super.init()
    }
    
    deinit {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    func startSession() {
        guard !captureSession.isRunning else { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Ensure setup is complete before starting
            if !self.isSetup {
                self.setupCameraSync()
            }
            
            // Start the session
            if self.isSetup && !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }
    
    private func getVideoOrientation() -> AVCaptureVideoOrientation {
        #if canImport(UIKit)
        switch UIDevice.current.orientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
        #else
        // macOS doesn't have device orientation
        return .portrait
        #endif
    }
    
    private func setupOrientationObserver() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVideoOrientation()
        }
        #endif
        // macOS doesn't need orientation observer
    }
    
    private func updateVideoOrientation() {
        guard let connection = photoOutput.connection(with: .video),
              connection.isVideoOrientationSupported else { return }
        
        let orientation = getVideoOrientation()
        connection.videoOrientation = orientation
    }
    
    private func setupCameraSync() {
        guard !isSetup else { return }
        
        captureSession.beginConfiguration()
        
        // Use 1920x1080 (Full HD) preset for consistent resolution across ALL platforms
        // This ensures overlays taken on one platform will match perfectly on another
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080  // 1920x1080 Full HD
            print("Camera: Using 1920x1080 preset for consistent overlay matching")
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
            print("Camera: Fallback to .high preset")
        }
        
        // Front camera for selfies
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            print("Front camera not available")
            captureSession.commitConfiguration()
            return
        }
        
        do {
            // Lock camera for configuration
            try frontCamera.lockForConfiguration()
            
            // Configure camera for maximum quality
            if frontCamera.isFocusModeSupported(.continuousAutoFocus) {
                frontCamera.focusMode = .continuousAutoFocus
            }
            if frontCamera.isExposureModeSupported(.continuousAutoExposure) {
                frontCamera.exposureMode = .continuousAutoExposure
            }
            if frontCamera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                frontCamera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            let input = try AVCaptureDeviceInput(device: frontCamera)
            deviceInput = input
            
            // Remove any existing inputs first
            for existingInput in captureSession.inputs {
                captureSession.removeInput(existingInput)
            }
            
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            // Remove any existing outputs
            for existingOutput in captureSession.outputs {
                captureSession.removeOutput(existingOutput)
            }
            
            if captureSession.canAddOutput(photoOutput) {
                captureSession.addOutput(photoOutput)
                
                // Configure photo output for best quality
                photoOutput.isHighResolutionCaptureEnabled = true
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
            
            captureSession.commitConfiguration()
            
            // Configure connections after committing
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
                if connection.isVideoOrientationSupported {
                    // Set orientation based on device orientation for better iPad support
                    let orientation = getVideoOrientation()
                    connection.videoOrientation = orientation
                }
            }
            
            frontCamera.unlockForConfiguration()
            isSetup = true
            
            // Listen for orientation changes
            setupOrientationObserver()
            
        } catch {
            print("Error setting up camera: \(error)")
            captureSession.commitConfiguration()
            frontCamera.unlockForConfiguration()
        }
    }
    
    func stopSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }
    
    func capturePhoto(completion: @escaping (PlatformImage?) -> Void) {
        captureCompletion = completion
        
        // Create maximum quality photo settings
        let settings: AVCapturePhotoSettings
        
        // Use JPEG format for best compatibility and quality
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        
        // Force 1920x1080 resolution by disabling high resolution capture
        // This ensures consistent resolution across all platforms for overlay matching
        settings.isHighResolutionPhotoEnabled = false
        #if canImport(UIKit)
        settings.isAutoStillImageStabilizationEnabled = photoOutput.isStillImageStabilizationSupported
        #endif
        settings.flashMode = .off // Front camera doesn't have flash
        
        // Set maximum quality prioritization
        if photoOutput.maxPhotoQualityPrioritization == .quality {
            settings.photoQualityPrioritization = .quality
        }
        
        // Debug: Log the settings being used
        print("Photo capture settings:")
        print("- High resolution enabled: \(settings.isHighResolutionPhotoEnabled)")
        #if canImport(UIKit)
        print("- Auto stabilization: \(settings.isAutoStillImageStabilizationEnabled)")
        #endif
        print("- Quality prioritization: \(settings.photoQualityPrioritization.rawValue)")
        print("- Format: \(settings.format)")
        
        #if canImport(UIKit)
        // Set orientation based on device orientation
        if let photoOutputConnection = photoOutput.connection(with: .video) {
            photoOutputConnection.videoOrientation = videoOrientation(from: UIDevice.current.orientation)
        }
        #endif
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }
    
    #if canImport(UIKit)
    private func videoOrientation(from deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
    #endif
}

// MARK: - Photo Capture Delegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation() else {
            captureCompletion?(nil)
            return
        }
        
        #if canImport(UIKit)
        guard let image = UIImage(data: imageData) else {
            captureCompletion?(nil)
            return
        }
        
        // Debug: Log the captured image details (match macOS format)
        print("Captured photo:")
        print("- Image size: \(image.size)")
        print("- Data size: \(imageData.count) bytes")
        
        captureCompletion?(image)
        
        #elseif canImport(AppKit)
        guard let image = NSImage(data: imageData) else {
            captureCompletion?(nil)
            return
        }
        
        // Debug: Log the captured image details
        print("Captured photo:")
        print("- Image size: \(image.size)")
        print("- Data size: \(imageData.count) bytes")
        
        captureCompletion?(image)
        #endif
    }
}

// MARK: - Camera View Wrapper

#if canImport(UIKit)
struct CameraViewWrapper: UIViewRepresentable {
    let cameraController: CameraController
    @Binding var capturedImage: PlatformImage?
    @Binding var showCapturedImage: Bool
    @Binding var showOverlay: Bool
    let lastPhotoImage: PlatformImage?
    let overlayOpacity: Double
    let onDismiss: () -> Void
    let onCapture: () -> Void
    let onSave: () -> Void
    
    func makeUIView(context: Context) -> CameraContainerView {
        let container = CameraContainerView()
        container.setupCamera(cameraController: cameraController)
        container.onDismiss = onDismiss
        container.onCapture = onCapture
        container.onSave = onSave
        container.capturedImage = capturedImage
        container.showCapturedImage = showCapturedImage
        container.lastPhotoImage = lastPhotoImage
        container.showOverlay = showOverlay
        container.overlayOpacity = overlayOpacity
        container.onToggleOverlay = {
            self.$showOverlay.wrappedValue.toggle()
        }
        return container
    }
    
    func updateUIView(_ uiView: CameraContainerView, context: Context) {
        uiView.capturedImage = capturedImage
        uiView.showCapturedImage = showCapturedImage
        uiView.showOverlay = showOverlay
        uiView.overlayOpacity = overlayOpacity
        uiView.updateUI()
    }
}

#elseif canImport(AppKit)
struct CameraViewWrapper: NSViewRepresentable {
    let cameraController: CameraController
    @Binding var capturedImage: PlatformImage?
    @Binding var showCapturedImage: Bool
    @Binding var showOverlay: Bool
    let lastPhotoImage: PlatformImage?
    let overlayOpacity: Double
    let onDismiss: () -> Void
    let onCapture: () -> Void
    let onSave: () -> Void
    
    func makeNSView(context: Context) -> CameraContainerView {
        let container = CameraContainerView()
        container.setupCamera(cameraController: cameraController)
        container.onDismiss = onDismiss
        container.onCapture = onCapture
        container.onSave = onSave
        container.capturedImage = capturedImage
        container.showCapturedImage = showCapturedImage
        container.lastPhotoImage = lastPhotoImage
        container.showOverlay = showOverlay
        container.overlayOpacity = overlayOpacity
        container.onToggleOverlay = {
            self.$showOverlay.wrappedValue.toggle()
        }
        return container
    }
    
    func updateNSView(_ nsView: CameraContainerView, context: Context) {
        nsView.capturedImage = capturedImage
        nsView.showCapturedImage = showCapturedImage
        nsView.showOverlay = showOverlay
        nsView.overlayOpacity = overlayOpacity
        nsView.updateUI()
    }
}
#endif

#if canImport(UIKit)
class CameraContainerView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var cameraController: CameraController?
    private var closeButton: UIButton!
    private var captureButton: UIButton!
    private var retakeButton: UIButton!
    private var saveButton: UIButton!
    private var imageView: UIImageView!
    private var overlayImageView: UIImageView!
    private var overlayToggleButton: UIButton!
    
    var onDismiss: (() -> Void)?
    var onCapture: (() -> Void)?
    var onSave: (() -> Void)?
    var onToggleOverlay: (() -> Void)?
    var overlayOpacity: Double = 0.4 {
        didSet {
            updateOverlayOpacity()
        }
    }
    
    var capturedImage: UIImage? {
        didSet {
            updateUI()
        }
    }
    
    var showCapturedImage: Bool = false {
        didSet {
            updateUI()
        }
    }
    
    var showOverlay: Bool = false {
        didSet {
            updateUI()
        }
    }
    
    var lastPhotoImage: UIImage? {
        didSet {
            overlayImageView?.image = lastPhotoImage
            overlayToggleButton?.isEnabled = lastPhotoImage != nil
            overlayToggleButton?.alpha = lastPhotoImage != nil ? 1.0 : 0.5
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupOrientationObserver()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func orientationDidChange() {
        updateVideoOrientation()
        setNeedsLayout()
        layoutIfNeeded()
    }
    
    func setupCamera(cameraController: CameraController) {
        self.cameraController = cameraController
        let layer = AVCaptureVideoPreviewLayer(session: cameraController.captureSession)
        layer.videoGravity = .resizeAspect  // Fit full feed without cropping
        
        // Ensure the layer connection is properly configured
        if let connection = layer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        self.layer.insertSublayer(layer, at: 0)
        self.previewLayer = layer
        
        // Update frames after adding the layer
        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
            self?.updateVideoOrientation()
        }
    }
    
    private func updateVideoOrientation() {
        guard let connection = previewLayer?.connection,
              connection.isVideoOrientationSupported else { return }
        
        let orientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        
        switch orientation {
        case .portrait:
            videoOrientation = .portrait
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        case .landscapeLeft:
            videoOrientation = .landscapeRight
        case .landscapeRight:
            videoOrientation = .landscapeLeft
        default:
            // Default based on interface orientation if device orientation is unknown
            if let windowScene = self.window?.windowScene {
                switch windowScene.interfaceOrientation {
                case .portrait:
                    videoOrientation = .portrait
                case .portraitUpsideDown:
                    videoOrientation = .portraitUpsideDown
                case .landscapeLeft:
                    videoOrientation = .landscapeLeft
                case .landscapeRight:
                    videoOrientation = .landscapeRight
                default:
                    videoOrientation = .portrait
                }
            } else {
                videoOrientation = .portrait
            }
        }
        
        // Update the connection on the main queue safely
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let connection = self.previewLayer?.connection,
                  connection.isVideoOrientationSupported else { return }
            connection.videoOrientation = videoOrientation
            self.cameraController?.updateVideoOrientation(videoOrientation)
        }
    }
    
    private func setupUI() {
        backgroundColor = .black
        
        // Overlay image view for previous photo (semi-transparent)
        overlayImageView = UIImageView()
        overlayImageView.contentMode = .scaleAspectFill
        overlayImageView.alpha = 0.4  // Default value, will be updated from PhotoStore
        overlayImageView.isHidden = true
        overlayImageView.isUserInteractionEnabled = false
        addSubview(overlayImageView)
        
        // Image view for captured photo
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isHidden = true
        addSubview(imageView)
        
        // Close button
        closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.contentVerticalAlignment = .fill
        closeButton.contentHorizontalAlignment = .fill
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        // Increase touch area for better iPad usability
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        addSubview(closeButton)
        
        // Overlay toggle button
        overlayToggleButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        overlayToggleButton.setImage(UIImage(systemName: "person.crop.rectangle.stack", withConfiguration: config), for: .normal)
        overlayToggleButton.setImage(UIImage(systemName: "person.crop.rectangle.stack.fill", withConfiguration: config), for: .selected)
        overlayToggleButton.tintColor = .white
        overlayToggleButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        overlayToggleButton.layer.cornerRadius = 8
        overlayToggleButton.addTarget(self, action: #selector(overlayToggleTapped), for: .touchUpInside)
        addSubview(overlayToggleButton)
        
        // Capture button
        captureButton = UIButton(type: .custom)
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 35
        captureButton.layer.borderWidth = 5
        captureButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        addSubview(captureButton)
        
        // Retake button
        retakeButton = UIButton(type: .system)
        retakeButton.setTitle("Retake", for: .normal)
        retakeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        retakeButton.setTitleColor(.white, for: .normal)
        retakeButton.backgroundColor = UIColor.systemGray.withAlphaComponent(0.8)
        retakeButton.layer.cornerRadius = 10
        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)
        addSubview(retakeButton)
        
        // Save button
        saveButton = UIButton(type: .system)
        saveButton.setTitle("Use Photo", for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = UIColor.systemBlue
        saveButton.layer.cornerRadius = 10
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        addSubview(saveButton)
        
        updateUI()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrame()
        updateButtonPositions()
    }
    
    private func getCameraAspectRatio() -> CGFloat {
        // Use the actual camera sensor aspect ratio for accurate preview
        // This prevents the "zoomed in" effect
        guard let cameraController = cameraController,
              let device = cameraController.deviceInput?.device else {
            // Fallback to 4:3 if we can't get the device
            print("Camera: Using fallback 4:3 aspect ratio")
            return 4.0 / 3.0
        }
        
        let activeFormat = device.activeFormat
        let formatDescription = activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let sensorAspectRatio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
        
        print("Camera: Sensor dimensions: \(dimensions.width)x\(dimensions.height), aspect ratio: \(sensorAspectRatio)")
        print("Camera: Using actual sensor aspect ratio for accurate preview")
        
        return sensorAspectRatio
    }
    
    private func updateFrame() {
        let isLandscape = bounds.width > bounds.height
        
        let previewFrame: CGRect
        
        // Get the actual camera resolution to match preview aspect ratio
        let cameraAspectRatio = getCameraAspectRatio()
        
        if isLandscape {
            // In landscape: fill the height, center horizontally with actual camera ratio
            let previewHeight = bounds.height
            let previewWidth = previewHeight * cameraAspectRatio
            let previewX = (bounds.width - previewWidth) / 2
            
            previewFrame = CGRect(x: previewX, y: 0, width: previewWidth, height: previewHeight)
            print("Camera: Landscape frame - bounds: \(bounds), preview: \(previewFrame), aspect: \(cameraAspectRatio)")
        } else {
            // In portrait: fill the width, center vertically with actual camera ratio
            let previewWidth = bounds.width
            let previewHeight = previewWidth / cameraAspectRatio
            let previewY = (bounds.height - previewHeight) / 2
            
            previewFrame = CGRect(x: 0, y: previewY, width: previewWidth, height: previewHeight)
            print("Camera: Portrait frame - bounds: \(bounds), preview: \(previewFrame), aspect: \(cameraAspectRatio)")
        }
        
        previewLayer?.frame = previewFrame
        previewLayer?.cornerRadius = 0
        previewLayer?.masksToBounds = true
        
        imageView.frame = previewFrame
        imageView.layer.cornerRadius = 0
        imageView.clipsToBounds = true
        
        overlayImageView.frame = previewFrame
        overlayImageView.layer.cornerRadius = 0
        overlayImageView.clipsToBounds = true
        
        // Debug logging for overlay positioning
        print("Overlay: frame = \(previewFrame), bounds = \(bounds), isHidden = \(overlayImageView.isHidden)")
    }
    
    private func updateButtonPositions() {
        let safeInsets = safeAreaInsets
        let buttonSize: CGFloat = 54  // Increased for better iPad usability
        let captureButtonSize: CGFloat = 70
        let margin: CGFloat = 20
        
        // Determine if we're in landscape based on bounds
        let isLandscape = bounds.width > bounds.height
        
        // Close button - top leading corner with safe area
        let closeX = safeInsets.left + margin
        let closeY = safeInsets.top + margin
        closeButton.frame = CGRect(x: closeX, y: closeY, width: buttonSize, height: buttonSize)
        
        // Debug logging for button positioning
        print("Close button: frame = \(closeButton.frame), safeInsets = \(safeInsets)")
        
        if !showCapturedImage {
            // Capture button - position based on orientation
            if isLandscape {
                // In landscape, button goes on the right side (trailing edge), centered vertically
                let captureX = bounds.width - safeInsets.right - margin - captureButtonSize
                captureButton.frame = CGRect(
                    x: captureX,
                    y: (bounds.height - captureButtonSize) / 2,
                    width: captureButtonSize,
                    height: captureButtonSize
                )
                
                // Overlay toggle button - above capture button in landscape
                let toggleSpacing: CGFloat = 20
                let toggleY = captureButton.frame.minY - buttonSize - toggleSpacing
                overlayToggleButton.frame = CGRect(
                    x: captureX + (captureButtonSize - buttonSize) / 2,
                    y: toggleY,
                    width: buttonSize,
                    height: buttonSize
                )
            } else {
                // In portrait, button goes at bottom center
                let captureY = bounds.height - safeInsets.bottom - margin - captureButtonSize
                captureButton.frame = CGRect(
                    x: (bounds.width - captureButtonSize) / 2,
                    y: captureY,
                    width: captureButtonSize,
                    height: captureButtonSize
                )
                
                // Overlay toggle button - to the left of capture button in portrait
                let toggleSpacing: CGFloat = 30
                let toggleX = captureButton.frame.minX - buttonSize - toggleSpacing
                overlayToggleButton.frame = CGRect(
                    x: toggleX,
                    y: captureY + (captureButtonSize - buttonSize) / 2,
                    width: buttonSize,
                    height: buttonSize
                )
            }
            captureButton.isHidden = false
            overlayToggleButton.isHidden = false
            retakeButton.isHidden = true
            saveButton.isHidden = true
        } else {
            // Retake and Save buttons - adapt to orientation
            let buttonHeight: CGFloat = 50
            let buttonWidth: CGFloat = 120
            let spacing: CGFloat = 20
            
            if isLandscape {
                // In landscape, stack buttons vertically on the right
                let buttonsX = bounds.width - safeInsets.right - margin - buttonWidth
                let totalHeight = (buttonHeight * 2) + spacing
                let startY = (bounds.height - totalHeight) / 2
                
                retakeButton.frame = CGRect(x: buttonsX, y: startY, width: buttonWidth, height: buttonHeight)
                saveButton.frame = CGRect(x: buttonsX, y: startY + buttonHeight + spacing, width: buttonWidth, height: buttonHeight)
            } else {
                // In portrait, buttons horizontally at bottom
                let totalWidth = (buttonWidth * 2) + spacing
                let startX = (bounds.width - totalWidth) / 2
                let buttonY = bounds.height - safeInsets.bottom - margin - buttonHeight
                
                retakeButton.frame = CGRect(x: startX, y: buttonY, width: buttonWidth, height: buttonHeight)
                saveButton.frame = CGRect(x: startX + buttonWidth + spacing, y: buttonY, width: buttonWidth, height: buttonHeight)
            }
            retakeButton.isHidden = false
            saveButton.isHidden = false
            captureButton.isHidden = true
            overlayToggleButton.isHidden = true
        }
    }
    
    func updateUI() {
        DispatchQueue.main.async {
            self.updateButtonPositions()
            
            if self.showCapturedImage, let image = self.capturedImage {
                self.imageView.image = image
                self.imageView.isHidden = false
                self.previewLayer?.isHidden = true
                self.overlayImageView.isHidden = true
            } else {
                self.imageView.isHidden = true
                self.previewLayer?.isHidden = false
                // Show overlay only if toggle is on and we have a last photo
                self.overlayImageView.isHidden = !self.showOverlay || self.lastPhotoImage == nil
                self.overlayToggleButton.isSelected = self.showOverlay
            }
        }
    }
    
    @objc private func closeTapped() {
        print("Close button tapped!")
        onDismiss?()
    }
    
    @objc private func captureTapped() {
        onCapture?()
    }
    
    @objc private func overlayToggleTapped() {
        onToggleOverlay?()
    }
    
    @objc private func retakeTapped() {
        showCapturedImage = false
        capturedImage = nil
        updateUI()
    }
    
    @objc private func saveTapped() {
        onSave?()
    }
    
    private func updateOverlayOpacity() {
        overlayImageView?.alpha = CGFloat(overlayOpacity)
    }
}
#endif

// MARK: - macOS Camera Container View

#if canImport(AppKit)
class CameraContainerView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var cameraController: CameraController?
    private var closeButton: NSButton!
    private var captureButton: NSButton!
    private var retakeButton: NSButton!
    private var saveButton: NSButton!
    private var imageView: NSImageView!
    private var overlayImageView: NSImageView!
    private var overlayToggleButton: NSButton!
    
    var onDismiss: (() -> Void)?
    var onCapture: (() -> Void)?
    var onSave: (() -> Void)?
    var onToggleOverlay: (() -> Void)?
    var overlayOpacity: Double = 0.4 {
        didSet {
            updateOverlayOpacity()
        }
    }
    
    var capturedImage: NSImage? {
        didSet {
            updateUI()
        }
    }
    
    var showCapturedImage: Bool = false {
        didSet {
            updateUI()
        }
    }
    
    var showOverlay: Bool = false {
        didSet {
            updateUI()
        }
    }
    
    var lastPhotoImage: NSImage? {
        didSet {
            overlayImageView?.image = lastPhotoImage
            overlayToggleButton?.isEnabled = lastPhotoImage != nil
            overlayToggleButton?.alphaValue = lastPhotoImage != nil ? 1.0 : 0.5
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setupCamera(cameraController: CameraController) {
        self.cameraController = cameraController
        let layer = AVCaptureVideoPreviewLayer(session: cameraController.captureSession)
        layer.videoGravity = .resizeAspect  // Fit full feed without cropping
        
        if let connection = layer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        
        self.wantsLayer = true
        self.layer?.insertSublayer(layer, at: 0)
        self.previewLayer = layer
        
        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
        }
    }
    
    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        
        // Overlay image view for previous photo
        overlayImageView = NSImageView()
        overlayImageView.imageScaling = .scaleProportionallyDown  // Fit within bounds like .resizeAspect
        overlayImageView.alphaValue = 0.4
        overlayImageView.isHidden = true
        addSubview(overlayImageView)
        
        // Image view for captured photo
        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown  // Fit captured image within bounds
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.isHidden = true
        addSubview(imageView)
        
        // Close button
        closeButton = NSButton()
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
        
        // Overlay toggle button
        overlayToggleButton = NSButton()
        overlayToggleButton.image = NSImage(systemSymbolName: "person.crop.rectangle.stack", accessibilityDescription: "Toggle Overlay")
        overlayToggleButton.isBordered = false
        overlayToggleButton.bezelStyle = .rounded
        overlayToggleButton.target = self
        overlayToggleButton.action = #selector(overlayToggleTapped)
        addSubview(overlayToggleButton)
        
        // Capture button
        captureButton = NSButton()
        captureButton.wantsLayer = true
        captureButton.layer?.backgroundColor = NSColor.white.cgColor
        captureButton.layer?.cornerRadius = 35
        captureButton.layer?.borderWidth = 5
        captureButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        captureButton.isBordered = false
        captureButton.target = self
        captureButton.action = #selector(captureTapped)
        addSubview(captureButton)
        
        // Retake button
        retakeButton = NSButton(title: "Retake", target: self, action: #selector(retakeTapped))
        retakeButton.wantsLayer = true
        retakeButton.bezelStyle = .rounded
        retakeButton.layer?.backgroundColor = NSColor.systemGray.cgColor
        retakeButton.layer?.cornerRadius = 10
        addSubview(retakeButton)
        
        // Save button
        saveButton = NSButton(title: "Use Photo", target: self, action: #selector(saveTapped))
        saveButton.wantsLayer = true
        saveButton.bezelStyle = .rounded
        saveButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        saveButton.layer?.cornerRadius = 10
        addSubview(saveButton)
        
        updateUI()
    }
    
    override func layout() {
        super.layout()
        updateFrame()
        updateButtonPositions()
    }
    
    private func updateFrame() {
        // Simple approach: let videoGravity and imageScaling handle aspect ratio
        // All layers fill bounds, they'll maintain aspect ratio internally
        previewLayer?.frame = bounds
        imageView.frame = bounds
        overlayImageView.frame = bounds
        
        print("macOS Camera: All layers set to bounds: \(bounds)")
    }
    
    private func updateButtonPositions() {
        let buttonSize: CGFloat = 54
        let captureButtonSize: CGFloat = 70
        let margin: CGFloat = 20
        
        // Close button - top left corner
        closeButton.frame = CGRect(x: margin, y: bounds.height - margin - buttonSize, width: buttonSize, height: buttonSize)
        
        if !showCapturedImage {
            // Capture button - bottom center
            let captureY = margin
            captureButton.frame = CGRect(
                x: (bounds.width - captureButtonSize) / 2,
                y: captureY,
                width: captureButtonSize,
                height: captureButtonSize
            )
            
            // Overlay toggle button - to the left of capture button
            let toggleSpacing: CGFloat = 30
            let toggleX = captureButton.frame.minX - buttonSize - toggleSpacing
            overlayToggleButton.frame = CGRect(
                x: toggleX,
                y: captureY + (captureButtonSize - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            )
            
            captureButton.isHidden = false
            overlayToggleButton.isHidden = false
            retakeButton.isHidden = true
            saveButton.isHidden = true
        } else {
            // Retake and Save buttons horizontally at bottom
            let buttonHeight: CGFloat = 50
            let buttonWidth: CGFloat = 120
            let spacing: CGFloat = 20
            let totalWidth = (buttonWidth * 2) + spacing
            let startX = (bounds.width - totalWidth) / 2
            let buttonY = margin
            
            retakeButton.frame = CGRect(x: startX, y: buttonY, width: buttonWidth, height: buttonHeight)
            saveButton.frame = CGRect(x: startX + buttonWidth + spacing, y: buttonY, width: buttonWidth, height: buttonHeight)
            
            retakeButton.isHidden = false
            saveButton.isHidden = false
            captureButton.isHidden = true
            overlayToggleButton.isHidden = true
        }
    }
    
    func updateUI() {
        DispatchQueue.main.async {
            self.updateButtonPositions()
            
            if self.showCapturedImage, let image = self.capturedImage {
                self.imageView.image = image
                self.imageView.isHidden = false
                self.previewLayer?.isHidden = true
                self.overlayImageView.isHidden = true
            } else {
                self.imageView.isHidden = true
                self.previewLayer?.isHidden = false
                self.overlayImageView.isHidden = !self.showOverlay || self.lastPhotoImage == nil
                self.overlayToggleButton.state = self.showOverlay ? .on : .off
            }
        }
    }
    
    @objc private func closeTapped() {
        onDismiss?()
    }
    
    @objc private func captureTapped() {
        onCapture?()
    }
    
    @objc private func overlayToggleTapped() {
        onToggleOverlay?()
    }
    
    @objc private func retakeTapped() {
        showCapturedImage = false
        capturedImage = nil
        updateUI()
    }
    
    @objc private func saveTapped() {
        onSave?()
    }
    
    private func updateOverlayOpacity() {
        overlayImageView?.alphaValue = CGFloat(overlayOpacity)
    }
}
#endif
