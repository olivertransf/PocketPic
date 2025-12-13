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
    #if canImport(UIKit)
    @State private var orientation = UIDeviceOrientation.portrait
    #endif
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
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = UIDevice.current.orientation
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientation = UIDevice.current.orientation
            cameraController.startSession()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            cameraController.stopSession()
        }
        #else
        .onAppear {
            cameraController.startSession()
        }
        .onDisappear {
            cameraController.stopSession()
        }
        #endif
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
        guard let image = capturedImage else {
            print("Error: No captured image to save")
            return
        }
        
        photoStore.savePhoto(image)
        
        // Dismiss after a brief delay to ensure save completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onDismiss?() ?? dismiss()
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
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func getVideoOrientation() -> AVCaptureVideoOrientation {
        #if canImport(UIKit)
        // Support landscape mode for camera preview
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
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
            // Note: updateVideoOrientation uses deprecated API for backward compatibility
            // Will migrate to AVCaptureDeviceRotationCoordinator in future iOS 17+ only version
            self?.updateVideoOrientation()
        }
        #endif
        // macOS doesn't need orientation observer
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func updateVideoOrientation() {
        guard let connection = photoOutput.connection(with: .video) else { return }
        #if canImport(UIKit)
        if #available(iOS 17.0, *) {
            // Use new rotation coordinator API in iOS 17+
            // For now, keep using old API for compatibility
        }
        #endif
        guard connection.isVideoOrientationSupported else { return }
        
        let orientation = getVideoOrientation()
        connection.videoOrientation = orientation
    }
    
    private func setupCameraSync() {
        guard !isSetup else { return }
        
        captureSession.beginConfiguration()
        
        #if canImport(UIKit)
        // iOS: Use high quality preset (allows portrait aspect ratios)
        // Portrait selfies work better with .high preset which supports various aspect ratios
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
            print("Camera: Using .high preset for portrait selfies (iOS)")
        } else if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
            print("Camera: Fallback to .photo preset")
        }
        #else
        // macOS: Keep existing preset for compatibility
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
            print("Camera: Using 1920x1080 preset (macOS)")
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
            print("Camera: Fallback to .high preset")
        }
        #endif
        
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
                #if canImport(UIKit)
                if #available(iOS 16.0, *) {
                    // Use maxPhotoDimensions for iOS 16+
                } else {
                    photoOutput.isHighResolutionCaptureEnabled = true
                }
                #endif
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
            
            captureSession.commitConfiguration()
            
            // Configure connections after committing
            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
                #if canImport(UIKit)
                // Note: Using deprecated videoOrientation API for backward compatibility
                // Will migrate to AVCaptureDeviceRotationCoordinator in future iOS 17+ only version
                if #available(iOS 17.0, *) {
                    // Use new rotation coordinator API in iOS 17+
                    // For now, keep using old API for compatibility
                }
                #endif
                if connection.isVideoOrientationSupported {
                    let orientation = getVideoOrientation()
                    connection.videoOrientation = orientation
                    print("Camera: Set video orientation to \(orientation.rawValue)")
                }
            }
            
            frontCamera.unlockForConfiguration()
            isSetup = true
            
            // Setup orientation observer for iOS
            #if canImport(UIKit)
            setupOrientationObserver()
            #elseif canImport(AppKit)
            // macOS: Keep orientation observer for compatibility
            setupOrientationObserver()
            #endif
            
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
        
        #if canImport(UIKit)
        // iOS: Enable high resolution for best portrait selfie quality
        // Portrait photos benefit from higher resolution
        if #available(iOS 16.0, *) {
            // Use maxPhotoDimensions for iOS 16+
            let maxDimensions = photoOutput.maxPhotoDimensions
            settings.maxPhotoDimensions = maxDimensions
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        #else
        // macOS: Keep existing setting
        #endif
        settings.flashMode = .off // Front camera doesn't have flash
        
        // Set maximum quality prioritization
        if photoOutput.maxPhotoQualityPrioritization == .quality {
            settings.photoQualityPrioritization = .quality
        }
        
        // Debug: Log the settings being used
        print("Photo capture settings:")
        #if canImport(UIKit)
        if #available(iOS 16.0, *) {
            // Use maxPhotoDimensions for iOS 16+
        } else {
            print("- High resolution enabled: \(settings.isHighResolutionPhotoEnabled)")
        }
        #endif
        print("- Quality prioritization: \(settings.photoQualityPrioritization.rawValue)")
        if let format = settings.format as? [String: Any] {
            print("- Format: \(format)")
        } else {
            print("- Format: \(String(describing: settings.format))")
        }
        
        #if canImport(UIKit)
        // Use current device orientation for photo capture
        // Note: Using deprecated videoOrientation API for backward compatibility
        if let photoOutputConnection = photoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                // Use new rotation coordinator API in iOS 17+
                // For now, keep using old API for compatibility
            }
            if photoOutputConnection.isVideoOrientationSupported {
                let orientation = getVideoOrientation()
                photoOutputConnection.videoOrientation = orientation
                print("Camera: Photo capture using orientation \(orientation.rawValue)")
            }
        }
        #endif
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let connection = self.photoOutput.connection(with: .video) {
                #if canImport(UIKit)
                if #available(iOS 17.0, *) {
                    // Use new rotation coordinator API in iOS 17+
                    // For now, keep using old API for compatibility
                }
                #endif
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }
    
    #if canImport(UIKit)
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func videoOrientation(from deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
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
    private var rotationIndicatorView: UIView!
    private var rotationIcon: UIImageView!
    private var rotationLabel: UILabel!
    private var orientationUpdateWorkItem: DispatchWorkItem?
    
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
    
    private var isLandscape: Bool {
        let orientation = UIDevice.current.orientation
        return orientation == .landscapeLeft || orientation == .landscapeRight || 
               (orientation == .unknown && bounds.width > bounds.height)
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
        // Cancel any pending orientation updates
        orientationUpdateWorkItem?.cancel()
        
        // Debounce orientation changes to prevent rapid updates
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Note: updateVideoOrientation uses deprecated API for backward compatibility
            self.updateVideoOrientation()
            self.updateFrame()
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        
        orientationUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
    
    func setupCamera(cameraController: CameraController) {
        self.cameraController = cameraController
        let layer = AVCaptureVideoPreviewLayer(session: cameraController.captureSession)
        layer.videoGravity = .resizeAspect  // Fit full feed without cropping
        
        // Ensure the layer connection is properly configured
        if let connection = layer.connection {
            #if canImport(UIKit)
            // Note: Using deprecated videoOrientation API for backward compatibility
            if #available(iOS 17.0, *) {
                // Use new rotation coordinator API in iOS 17+
                // For now, keep using old API for compatibility
            }
            #endif
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
        
        self.layer.insertSublayer(layer, at: 0)
        self.previewLayer = layer
        
        // Update frames after adding the layer
        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
            // Note: updateVideoOrientation uses deprecated API for backward compatibility
            self?.updateVideoOrientation()
            // Ensure preview is visible
            self?.previewLayer?.isHidden = false
        }
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func updateVideoOrientation() {
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateVideoOrientation()
            }
            return
        }
        
        guard let connection = previewLayer?.connection else { return }
        
        #if canImport(UIKit)
        if #available(iOS 17.0, *) {
            // Use new rotation coordinator API in iOS 17+
            // For now, keep using old API for compatibility
        }
        #endif
        
        guard connection.isVideoOrientationSupported else { return }
        
        let deviceOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        
        switch deviceOrientation {
        case .landscapeLeft:
            videoOrientation = .landscapeRight
        case .landscapeRight:
            videoOrientation = .landscapeLeft
        case .portraitUpsideDown:
            videoOrientation = .portraitUpsideDown
        default:
            videoOrientation = .portrait
        }
        
        // Update the connection synchronously on main thread
        connection.videoOrientation = videoOrientation
        cameraController?.updateVideoOrientation(videoOrientation)
        updateRotationIndicator()
        
        // Force preview layer to update
        previewLayer?.frame = previewLayer?.frame ?? .zero
    }
    
    private func setupUI() {
        backgroundColor = .black
        
        // Rotation indicator view
        rotationIndicatorView = UIView()
        rotationIndicatorView.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        rotationIndicatorView.layer.cornerRadius = 20
        rotationIndicatorView.isHidden = true
        addSubview(rotationIndicatorView)
        
        // Rotation icon
        rotationIcon = UIImageView()
        rotationIcon.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        rotationIcon.tintColor = .white
        rotationIcon.contentMode = .scaleAspectFit
        rotationIndicatorView.addSubview(rotationIcon)
        
        // Rotation label
        rotationLabel = UILabel()
        rotationLabel.text = "Rotate to Landscape"
        rotationLabel.textColor = .white
        rotationLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        rotationLabel.textAlignment = .center
        rotationIndicatorView.addSubview(rotationLabel)
        
        // Overlay image view for previous photo (semi-transparent)
        overlayImageView = UIImageView()
        overlayImageView.contentMode = .scaleAspectFit
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
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            closeButton.configuration = config
        } else {
            closeButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        }
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
        retakeButton.backgroundColor = UIColor.systemGray.withAlphaComponent(0.9)
        retakeButton.layer.cornerRadius = 12
        retakeButton.layer.shadowColor = UIColor.black.cgColor
        retakeButton.layer.shadowOpacity = 0.2
        retakeButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        retakeButton.layer.shadowRadius = 4
        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)
        addSubview(retakeButton)
        
        // Save button
        saveButton = UIButton(type: .system)
        saveButton.setTitle("Use Photo", for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = UIColor.systemBlue
        saveButton.layer.cornerRadius = 12
        saveButton.layer.shadowColor = UIColor.systemBlue.cgColor
        saveButton.layer.shadowOpacity = 0.4
        saveButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        saveButton.layer.shadowRadius = 8
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        addSubview(saveButton)
        
        updateUI()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrame()
        updateButtonPositions()
        updateRotationIndicator()
    }
    
    private func updateRotationIndicator() {
        let shouldShow = !isLandscape && !showCapturedImage
        rotationIndicatorView.isHidden = !shouldShow
        
        if shouldShow {
            // Center the rotation indicator
            let indicatorWidth: CGFloat = 280
            let indicatorHeight: CGFloat = 120
            rotationIndicatorView.frame = CGRect(
                x: (bounds.width - indicatorWidth) / 2,
                y: (bounds.height - indicatorHeight) / 2,
                width: indicatorWidth,
                height: indicatorHeight
            )
            
            // Layout icon and label
            let iconSize: CGFloat = 50
            rotationIcon.frame = CGRect(
                x: (indicatorWidth - iconSize) / 2,
                y: 20,
                width: iconSize,
                height: iconSize
            )
            
            rotationLabel.frame = CGRect(
                x: 20,
                y: 75,
                width: indicatorWidth - 40,
                height: 25
            )
        }
    }
    
    private func getCameraAspectRatio() -> CGFloat {
        // Calculate aspect ratio based on current orientation
        guard let cameraController = cameraController,
              let device = cameraController.deviceInput?.device else {
            // Fallback aspect ratios
            if isLandscape {
                return 16.0 / 9.0  // Landscape 16:9
            } else {
                return 9.0 / 16.0  // Portrait 9:16
            }
        }
        
        let activeFormat = device.activeFormat
        let formatDescription = activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        
        // Calculate aspect ratio based on orientation
        if isLandscape {
            // Landscape: width/height
            let sensorAspectRatio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            print("Camera: Landscape - dimensions: \(dimensions.width)x\(dimensions.height), aspect ratio: \(sensorAspectRatio)")
            return sensorAspectRatio
        } else {
            // Portrait: height/width (flipped from sensor)
            let sensorAspectRatio = CGFloat(dimensions.height) / CGFloat(dimensions.width)
            print("Camera: Portrait - dimensions: \(dimensions.width)x\(dimensions.height), aspect ratio: \(sensorAspectRatio)")
            return sensorAspectRatio
        }
    }
    
    private func updateFrame() {
        // Ensure we're on the main thread
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateFrame()
            }
            return
        }
        
        // Support both portrait and landscape orientations
        let previewFrame: CGRect
        
        if isLandscape {
            // Landscape mode: fill the height, center horizontally
            let cameraAspectRatio = getCameraAspectRatio()
            let previewHeight = bounds.height
            let previewWidth = previewHeight * cameraAspectRatio
            let previewX = (bounds.width - previewWidth) / 2
            
            previewFrame = CGRect(x: previewX, y: 0, width: previewWidth, height: previewHeight)
        } else {
            // Portrait mode: fill the width, center vertically
            let cameraAspectRatio = getCameraAspectRatio()
            let previewWidth = bounds.width
            let previewHeight = previewWidth / cameraAspectRatio
            let previewY = (bounds.height - previewHeight) / 2
            
            previewFrame = CGRect(x: 0, y: previewY, width: previewWidth, height: previewHeight)
        }
        
        // Update preview layer frame
        if let previewLayer = previewLayer {
            previewLayer.frame = previewFrame
            previewLayer.cornerRadius = 0
            previewLayer.masksToBounds = true
        }
        
        // Update image view frame
        imageView.frame = previewFrame
        imageView.layer.cornerRadius = 0
        imageView.clipsToBounds = true
        
        // Update overlay image view frame
        overlayImageView.frame = previewFrame
        overlayImageView.layer.cornerRadius = 0
        overlayImageView.clipsToBounds = true
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
            self.updateRotationIndicator()
            
            if self.showCapturedImage, let image = self.capturedImage {
                self.imageView.image = image
                self.imageView.isHidden = false
                self.previewLayer?.isHidden = true
                self.overlayImageView.isHidden = true
                self.rotationIndicatorView.isHidden = true
            } else {
                self.imageView.isHidden = true
                // Always show preview layer, but show rotation indicator overlay in portrait
                self.previewLayer?.isHidden = false
                // Show overlay only if toggle is on, we have a last photo, and we're in landscape
                let shouldShowOverlay = self.isLandscape && self.showOverlay && self.lastPhotoImage != nil
                self.overlayImageView.isHidden = !shouldShowOverlay
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
        retakeButton.layer?.cornerRadius = 12
        retakeButton.layer?.shadowColor = NSColor.black.cgColor
        retakeButton.layer?.shadowOpacity = 0.2
        retakeButton.layer?.shadowOffset = CGSize(width: 0, height: 2)
        retakeButton.layer?.shadowRadius = 4
        if let cell = retakeButton.cell as? NSButtonCell {
            cell.attributedTitle = NSAttributedString(
                string: "Retake",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: 17, weight: .semibold)
                ]
            )
        }
        addSubview(retakeButton)
        
        // Save button
        saveButton = NSButton(title: "Use Photo", target: self, action: #selector(saveTapped))
        saveButton.wantsLayer = true
        saveButton.bezelStyle = .rounded
        saveButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        saveButton.layer?.cornerRadius = 12
        saveButton.layer?.shadowColor = NSColor.systemBlue.cgColor
        saveButton.layer?.shadowOpacity = 0.4
        saveButton.layer?.shadowOffset = CGSize(width: 0, height: 4)
        saveButton.layer?.shadowRadius = 8
        if let cell = saveButton.cell as? NSButtonCell {
            cell.attributedTitle = NSAttributedString(
                string: "Use Photo",
                attributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: 17, weight: .semibold)
                ]
            )
        }
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
