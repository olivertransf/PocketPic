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
    private var isConfiguring = false
    private let configQueue = DispatchQueue(label: "CameraControllerConfigQueue")
    var deviceInput: AVCaptureDeviceInput?
    
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var currentCamera: AVCaptureDevice?
    
    override init() {
        super.init()
        requestCameraPermissionAndDiscover()
        setupDeviceNotifications()
    }
    
    private func requestCameraPermissionAndDiscover() {
        #if canImport(UIKit)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            discoverCameras()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.discoverCameras()
                    } else {
                        print("Camera permission denied")
                    }
                }
            }
        case .denied, .restricted:
            print("Camera permission denied or restricted")
        @unknown default:
            print("Unknown camera permission status")
        }
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            discoverCameras()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.discoverCameras()
                    } else {
                        print("Camera permission denied")
                    }
                }
            }
        case .denied, .restricted:
            print("Camera permission denied or restricted")
        @unknown default:
            print("Unknown camera permission status")
        }
        #endif
    }
    
    private func discoverCameras() {
        #if canImport(UIKit)
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let allDevices = discoverySession.devices
        let discoveredCameras = allDevices.filter { $0.hasMediaType(.video) }
        #else
        var allDevices: [AVCaptureDevice] = []
        
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera
        ]
        
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        } else {
            deviceTypes.append(.externalUnknown)
        }
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        
        allDevices = discoverySession.devices
        
        if allDevices.isEmpty {
            print("Discovery session found no devices, trying alternative methods...")
            
            if let defaultDevice = AVCaptureDevice.default(for: .video) {
                allDevices = [defaultDevice]
                print("Found default camera: \(defaultDevice.localizedName)")
            }
            
            if allDevices.isEmpty {
                let allDeviceTypes: [AVCaptureDevice.DeviceType]
                if #available(macOS 14.0, *) {
                    allDeviceTypes = [.builtInWideAngleCamera, .external]
                } else {
                    allDeviceTypes = [.builtInWideAngleCamera, .externalUnknown]
                }
                
                let fallbackSession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: allDeviceTypes,
                    mediaType: .video,
                    position: .unspecified
                )
                allDevices = fallbackSession.devices
                print("Fallback discovery found: \(allDevices.count) devices")
            }
            
            if allDevices.isEmpty {
                print("Attempting to enumerate all devices without type filter...")
                let allVideoSession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInWideAngleCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                allDevices = allVideoSession.devices
                print("Basic discovery found: \(allDevices.count) devices")
            }
        }
        
        let discoveredCameras = allDevices.filter { device in
            let isConnected = device.isConnected
            let hasVideo = device.hasMediaType(.video)
            let notSuspended = !device.isSuspended
            let notInUse = !device.isInUseByAnotherApplication
            
            return isConnected && hasVideo && notSuspended && notInUse
        }
        #endif
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let hadCameras = !self.availableCameras.isEmpty
            let previousCamera = self.currentCamera
            
            self.availableCameras = discoveredCameras
            
            let firstCamera = discoveredCameras.first
            
            if self.currentCamera == nil || !(discoveredCameras.contains { $0.uniqueID == self.currentCamera?.uniqueID }) {
                self.currentCamera = firstCamera
                print("Selected camera: \(self.currentCamera?.localizedName ?? "none")")
            }
            
            if !hadCameras && !discoveredCameras.isEmpty && self.currentCamera != nil {
                if !self.isSetup {
                    self.configQueue.async { [weak self] in
                        guard let self = self else { return }
                        self.setupCameraSync() // Only beginConfiguration/commitConfiguration here!
                        // Important: Only startRunning after configuration block is done
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            if self.isSetup && !self.captureSession.isRunning {
                                self.captureSession.startRunning()
                            }
                        }
                    }
                }
            }
            
            if discoveredCameras.isEmpty {
                print("Warning: No cameras discovered.")
                print("Total devices found: \(allDevices.count)")
                if allDevices.isEmpty {
                    print("No devices found at all. This may indicate:")
                    print("  - Camera permission not granted")
                    print("  - Missing device-camera entitlement (check entitlements file)")
                    print("  - No cameras connected to the system")
                } else {
                    print("Devices found but filtered out:")
                    for device in allDevices {
                        print("  - \(device.localizedName)")
                        print("    ID: \(device.uniqueID)")
                        print("    Has Video: \(device.hasMediaType(.video))")
                    }
                }
            } else {
                print("Discovered \(discoveredCameras.count) camera(s):")
                for camera in discoveredCameras {
                    print("  - \(camera.localizedName) (ID: \(camera.uniqueID))")
                }
            }
        }
    }
    
    private func setupDeviceNotifications() {
        let connectedNotification: Notification.Name
        let disconnectedNotification: Notification.Name
        
        if #available(macOS 15.0, iOS 17.0, *) {
            connectedNotification = AVCaptureDevice.wasConnectedNotification
            disconnectedNotification = AVCaptureDevice.wasDisconnectedNotification
        } else {
            connectedNotification = .AVCaptureDeviceWasConnected
            disconnectedNotification = .AVCaptureDeviceWasDisconnected
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceConnected(_:)),
            name: connectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDisconnected(_:)),
            name: disconnectedNotification,
            object: nil
        )
    }
    
    @objc private func deviceConnected(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .authorized {
                self?.discoverCameras()
            } else {
                self?.requestCameraPermissionAndDiscover()
            }
        }
    }
    
    @objc private func deviceDisconnected(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            self.discoverCameras()
            if let newCamera = self.availableCameras.first {
                self.switchCamera(to: newCamera)
            } else {
                self.currentCamera = nil
            }
        }
    }
    
    func switchCamera(to device: AVCaptureDevice) {
        if let current = currentCamera, current.uniqueID == device.uniqueID { return }
        guard availableCameras.contains(where: { $0.uniqueID == device.uniqueID }) else { return }
        configQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.isConfiguring = true
            self.captureSession.beginConfiguration()
            
            if let existingInput = self.deviceInput {
                self.captureSession.removeInput(existingInput)
            }
            
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                
                let input = try AVCaptureDeviceInput(device: device)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                    self.deviceInput = input
                    DispatchQueue.main.async {
                        self.currentCamera = device
                    }
                }
                
                device.unlockForConfiguration()
            } catch {
                print("Error switching camera: \(error)")
            }
            
            self.captureSession.commitConfiguration()
            self.isConfiguring = false
        }
    }
    
    deinit {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    func startSession() {
        // Only start/call startRunning after any configuration block has ended
        guard !captureSession.isRunning else { return }
        
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            requestCameraPermissionAndDiscover()
            return
        }

        // Wait until not in config
        configQueue.async { [weak self] in
            guard let self = self else { return }
            // Wait for setup if needed
            if self.availableCameras.isEmpty {
                return
            }
            
            if !self.isSetup {
                self.setupCameraSync()
            }
            
            // Wait for any config block to finish before starting session
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isSetup && !self.captureSession.isRunning && !self.isConfiguring {
                    self.captureSession.startRunning()
                }
            }
        }
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func getVideoOrientation() -> AVCaptureVideoOrientation {
        #if canImport(UIKit)
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
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func updateVideoOrientation() {
        guard let connection = photoOutput.connection(with: .video) else { return }
        #if canImport(UIKit)
        if #available(iOS 17.0, *) { }
        #endif
        guard connection.isVideoOrientationSupported else { return }
        
        let orientation = getVideoOrientation()
        connection.videoOrientation = orientation
    }
    
    // WARNING: Must not call captureSession.startRunning inside begin/commit!
    private func setupCameraSync() {
        if availableCameras.isEmpty {
            print("No cameras available yet, discovering...")
            discoverCameras()
            return
        }
        
        let currentDevice = deviceInput?.device
        if isSetup && currentDevice?.uniqueID == currentCamera?.uniqueID {
            print("Camera already set up with: \(currentDevice?.localizedName ?? "unknown")")
            return
        }
        
        if isSetup && currentDevice?.uniqueID != currentCamera?.uniqueID {
            print("Switching from \(currentDevice?.localizedName ?? "unknown") to \(currentCamera?.localizedName ?? "unknown")")
            isSetup = false
        }
        
        let camera = currentCamera ?? availableCameras.first
        
        guard let camera = camera else {
            print("Error: No camera available. Please check:")
            discoverCameras()
            return
        }
        
        print("Setting up camera: \(camera.localizedName)")
        isConfiguring = true
        captureSession.beginConfiguration()
        
        #if canImport(UIKit)
        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        } else if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        }
        #else
        if captureSession.canSetSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        #endif
        
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            
            let input = try AVCaptureDeviceInput(device: camera)
            deviceInput = input
            
            for existingInput in captureSession.inputs {
                captureSession.removeInput(existingInput)
            }
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            for existingOutput in captureSession.outputs {
                captureSession.removeOutput(existingOutput)
            }
            if captureSession.canAddOutput(photoOutput) {
                captureSession.addOutput(photoOutput)
                #if canImport(UIKit)
                if #available(iOS 16.0, *) {
                } else {
                    photoOutput.isHighResolutionCaptureEnabled = true
                }
                #endif
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
            captureSession.commitConfiguration()
            isConfiguring = false
            
            if let connection = photoOutput.connection(with: .video) {
                #if canImport(UIKit)
                if connection.isVideoMirroringSupported && camera.position == .front {
                    connection.isVideoMirrored = true
                }
                #else
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
                #endif
                if connection.isVideoOrientationSupported {
                    let orientation = getVideoOrientation()
                    connection.videoOrientation = orientation
                }
            }
            camera.unlockForConfiguration()
            isSetup = true
            #if canImport(UIKit)
            setupOrientationObserver()
            #elseif canImport(AppKit)
            setupOrientationObserver()
            #endif
        } catch {
            print("Error setting up camera: \(error)")
            captureSession.commitConfiguration()
            isConfiguring = false
            camera.unlockForConfiguration()
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
        guard currentCamera != nil, deviceInput?.device == currentCamera else {
            print("Capture photo called, but currentCamera is nil or not setup")
            completion(nil)
            return
        }
        guard captureSession.inputs.count > 0, captureSession.outputs.contains(photoOutput) else {
            print("Capture photo called, but session has no input/output")
            completion(nil)
            return
        }

        captureCompletion = completion
        
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        
        #if canImport(UIKit)
        if #available(iOS 16.0, *) {
            let maxDimensions = photoOutput.maxPhotoDimensions
            settings.maxPhotoDimensions = maxDimensions
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        #endif
        settings.flashMode = .off
        if photoOutput.maxPhotoQualityPrioritization == .quality {
            settings.photoQualityPrioritization = .quality
        }
        
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let connection = self.photoOutput.connection(with: .video) {
                #if canImport(UIKit)
                if #available(iOS 17.0, *) { }
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
        captureCompletion?(image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: imageData) else {
            captureCompletion?(nil)
            return
        }
        captureCompletion?(image)
        #endif
    }
}

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
        uiView.cameraController = cameraController
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
        nsView.cameraController = cameraController
        nsView.updateUI()
    }
}
#endif

#if canImport(UIKit)
class CameraContainerView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    var cameraController: CameraController?
    private var closeButton: UIButton!
    private var captureButton: UIButton!
    private var retakeButton: UIButton!
    private var saveButton: UIButton!
    private var imageView: UIImageView!
    private var overlayImageView: UIImageView!
    private var overlayToggleButton: UIButton!
    private var cameraSwitchButton: UIButton!
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
        orientationUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
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
        layer.videoGravity = .resizeAspect
        if let connection = layer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        self.layer.insertSublayer(layer, at: 0)
        self.previewLayer = layer
        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
            self?.updateVideoOrientation()
            self?.previewLayer?.isHidden = false
        }
    }
    
    @available(iOS, deprecated: 17.0, message: "Use AVCaptureDeviceRotationCoordinator instead")
    private func updateVideoOrientation() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateVideoOrientation()
            }
            return
        }
        
        guard let connection = previewLayer?.connection else { return }
        #if canImport(UIKit)
        if #available(iOS 17.0, *) { }
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
        connection.videoOrientation = videoOrientation
        cameraController?.updateVideoOrientation(videoOrientation)
        updateRotationIndicator()
        previewLayer?.frame = previewLayer?.frame ?? .zero
    }
    
    private func setupUI() {
        backgroundColor = .black
        
        rotationIndicatorView = UIView()
        rotationIndicatorView.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        rotationIndicatorView.layer.cornerRadius = 20
        rotationIndicatorView.isHidden = true
        addSubview(rotationIndicatorView)
        
        rotationIcon = UIImageView()
        rotationIcon.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        rotationIcon.tintColor = .white
        rotationIcon.contentMode = .scaleAspectFit
        rotationIndicatorView.addSubview(rotationIcon)
        
        rotationLabel = UILabel()
        rotationLabel.text = "Rotate to Landscape"
        rotationLabel.textColor = .white
        rotationLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        rotationLabel.textAlignment = .center
        rotationIndicatorView.addSubview(rotationLabel)
        
        overlayImageView = UIImageView()
        overlayImageView.contentMode = .scaleAspectFit
        overlayImageView.alpha = 0.4
        overlayImageView.isHidden = true
        overlayImageView.isUserInteractionEnabled = false
        addSubview(overlayImageView)
        
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.isHidden = true
        addSubview(imageView)
        
        closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.contentVerticalAlignment = .fill
        closeButton.contentHorizontalAlignment = .fill
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            closeButton.configuration = config
        } else {
            closeButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        }
        addSubview(closeButton)
        
        overlayToggleButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        overlayToggleButton.setImage(UIImage(systemName: "person.crop.rectangle.stack", withConfiguration: config), for: .normal)
        overlayToggleButton.setImage(UIImage(systemName: "person.crop.rectangle.stack.fill", withConfiguration: config), for: .selected)
        overlayToggleButton.tintColor = .white
        overlayToggleButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        overlayToggleButton.layer.cornerRadius = 8
        overlayToggleButton.addTarget(self, action: #selector(overlayToggleTapped), for: .touchUpInside)
        addSubview(overlayToggleButton)
        
        cameraSwitchButton = UIButton(type: .system)
        let cameraConfig = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        cameraSwitchButton.setImage(UIImage(systemName: "camera.rotate", withConfiguration: cameraConfig), for: .normal)
        cameraSwitchButton.tintColor = .white
        cameraSwitchButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        cameraSwitchButton.layer.cornerRadius = 8
        cameraSwitchButton.addTarget(self, action: #selector(cameraSwitchTapped), for: .touchUpInside)
        addSubview(cameraSwitchButton)
        
        captureButton = UIButton(type: .custom)
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 35
        captureButton.layer.borderWidth = 5
        captureButton.layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        addSubview(captureButton)
        
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
            let indicatorWidth: CGFloat = 280
            let indicatorHeight: CGFloat = 120
            rotationIndicatorView.frame = CGRect(
                x: (bounds.width - indicatorWidth) / 2,
                y: (bounds.height - indicatorHeight) / 2,
                width: indicatorWidth,
                height: indicatorHeight
            )
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
        guard let cameraController = cameraController,
              let device = cameraController.deviceInput?.device else {
            if isLandscape { return 16.0 / 9.0 }
            else { return 9.0 / 16.0 }
        }
        
        let activeFormat = device.activeFormat
        let formatDescription = activeFormat.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        
        if isLandscape {
            let sensorAspectRatio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            return sensorAspectRatio
        } else {
            let sensorAspectRatio = CGFloat(dimensions.height) / CGFloat(dimensions.width)
            return sensorAspectRatio
        }
    }
    
    private func updateFrame() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateFrame() }
            return
        }
        let previewFrame: CGRect
        
        if isLandscape {
            let cameraAspectRatio = getCameraAspectRatio()
            let previewHeight = bounds.height
            let previewWidth = previewHeight * cameraAspectRatio
            let previewX = (bounds.width - previewWidth) / 2
            previewFrame = CGRect(x: previewX, y: 0, width: previewWidth, height: previewHeight)
        } else {
            let cameraAspectRatio = getCameraAspectRatio()
            let previewWidth = bounds.width
            let previewHeight = previewWidth / cameraAspectRatio
            let previewY = (bounds.height - previewHeight) / 2
            previewFrame = CGRect(x: 0, y: previewY, width: previewWidth, height: previewHeight)
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
    }
    
    private func updateButtonPositions() {
        let safeInsets = safeAreaInsets
        let buttonSize: CGFloat = 54
        let captureButtonSize: CGFloat = 70
        let margin: CGFloat = 20
        
        let isLandscape = bounds.width > bounds.height
        let closeX = safeInsets.left + margin
        let closeY = safeInsets.top + margin
        closeButton.frame = CGRect(x: closeX, y: closeY, width: buttonSize, height: buttonSize)
        
        if !showCapturedImage {
            if isLandscape {
                let captureX = bounds.width - safeInsets.right - margin - captureButtonSize
                captureButton.frame = CGRect(
                    x: captureX,
                    y: (bounds.height - captureButtonSize) / 2,
                    width: captureButtonSize,
                    height: captureButtonSize
                )
                let toggleSpacing: CGFloat = 20
                let toggleY = captureButton.frame.minY - buttonSize - toggleSpacing
                overlayToggleButton.frame = CGRect(
                    x: captureX + (captureButtonSize - buttonSize) / 2,
                    y: toggleY,
                    width: buttonSize,
                    height: buttonSize
                )
                let cameraSwitchY = toggleY - buttonSize - toggleSpacing
                cameraSwitchButton.frame = CGRect(
                    x: captureX + (captureButtonSize - buttonSize) / 2,
                    y: cameraSwitchY,
                    width: buttonSize,
                    height: buttonSize
                )
            } else {
                let captureY = bounds.height - safeInsets.bottom - margin - captureButtonSize
                captureButton.frame = CGRect(
                    x: (bounds.width - captureButtonSize) / 2,
                    y: captureY,
                    width: captureButtonSize,
                    height: captureButtonSize
                )
                let toggleSpacing: CGFloat = 30
                let toggleX = captureButton.frame.minX - buttonSize - toggleSpacing
                overlayToggleButton.frame = CGRect(
                    x: toggleX,
                    y: captureY + (captureButtonSize - buttonSize) / 2,
                    width: buttonSize,
                    height: buttonSize
                )
                let cameraSwitchX = captureButton.frame.maxX + toggleSpacing
                cameraSwitchButton.frame = CGRect(
                    x: cameraSwitchX,
                    y: captureY + (captureButtonSize - buttonSize) / 2,
                    width: buttonSize,
                    height: buttonSize
                )
            }
            captureButton.isHidden = false
            overlayToggleButton.isHidden = false
            let cameraCount = cameraController?.availableCameras.count ?? 0
            cameraSwitchButton.isHidden = cameraCount <= 1
            retakeButton.isHidden = true
            saveButton.isHidden = true
        } else {
            let buttonHeight: CGFloat = 50
            let buttonWidth: CGFloat = 120
            let spacing: CGFloat = 20
            
            if isLandscape {
                let buttonsX = bounds.width - safeInsets.right - margin - buttonWidth
                let totalHeight = (buttonHeight * 2) + spacing
                let startY = (bounds.height - totalHeight) / 2
                retakeButton.frame = CGRect(x: buttonsX, y: startY, width: buttonWidth, height: buttonHeight)
                saveButton.frame = CGRect(x: buttonsX, y: startY + buttonHeight + spacing, width: buttonWidth, height: buttonHeight)
            } else {
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
            cameraSwitchButton.isHidden = true
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
                self.previewLayer?.isHidden = false
                let shouldShowOverlay = self.isLandscape && self.showOverlay && self.lastPhotoImage != nil
                self.overlayImageView.isHidden = !shouldShowOverlay
                self.overlayToggleButton.isSelected = self.showOverlay
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
    
    @objc private func cameraSwitchTapped() {
        guard let cameraController = cameraController else { return }
        let availableCameras = cameraController.availableCameras
        guard availableCameras.count > 1 else { return }
        guard let current = cameraController.currentCamera else { return }
        let currentIndex = availableCameras.firstIndex(where: { $0.uniqueID == current.uniqueID }) ?? 0
        let nextIndex = (currentIndex + 1) % availableCameras.count
        let nextCamera = availableCameras[nextIndex]
        cameraController.switchCamera(to: nextCamera)
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

#if canImport(AppKit)
class CameraContainerView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    var cameraController: CameraController?
    private var closeButton: NSButton!
    private var captureButton: NSButton!
    private var retakeButton: NSButton!
    private var saveButton: NSButton!
    private var imageView: NSImageView!
    private var overlayImageView: NSImageView!
    private var overlayToggleButton: NSButton!
    private var cameraSwitchButton: NSButton!
    
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
            overlayToggleButton?.contentTintColor = lastPhotoImage != nil ? .white : .disabledControlTextColor
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func makeIconButton(symbol: String, size: CGFloat = 18) -> NSButton {
        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        btn.isBordered = false
        btn.contentTintColor = .white
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        btn.layer?.cornerRadius = 10
        btn.target = self
        return btn
    }
    
    func setupCamera(cameraController: CameraController) {
        self.cameraController = cameraController
        let layer = AVCaptureVideoPreviewLayer(session: cameraController.captureSession)
        layer.videoGravity = .resizeAspect
        layer.cornerRadius = 12
        layer.masksToBounds = true
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
        
        overlayImageView = NSImageView()
        overlayImageView.imageScaling = .scaleProportionallyDown
        overlayImageView.alphaValue = 0.4
        overlayImageView.isHidden = true
        addSubview(overlayImageView)
        
        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.isHidden = true
        addSubview(imageView)
        
        closeButton = makeIconButton(symbol: "xmark.circle.fill", size: 22)
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
        
        overlayToggleButton = makeIconButton(symbol: "person.crop.rectangle.stack")
        overlayToggleButton.action = #selector(overlayToggleTapped)
        addSubview(overlayToggleButton)
        
        cameraSwitchButton = makeIconButton(symbol: "camera.rotate")
        cameraSwitchButton.action = #selector(cameraSwitchTapped)
        addSubview(cameraSwitchButton)
        
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
        let margin: CGFloat = 16
        let previewRect = bounds.insetBy(dx: margin, dy: margin)
        previewLayer?.frame = previewRect
        imageView.frame = previewRect
        imageView.layer?.cornerRadius = 12
        overlayImageView.frame = previewRect
    }
    
    private func updateButtonPositions() {
        let buttonSize: CGFloat = 54
        let captureButtonSize: CGFloat = 70
        let margin: CGFloat = 20
        
        closeButton.frame = CGRect(x: margin, y: bounds.height - margin - buttonSize, width: buttonSize, height: buttonSize)
        
        if !showCapturedImage {
            let captureY = margin
            captureButton.frame = CGRect(
                x: (bounds.width - captureButtonSize) / 2,
                y: captureY,
                width: captureButtonSize,
                height: captureButtonSize
            )
            let toggleSpacing: CGFloat = 30
            let toggleX = captureButton.frame.minX - buttonSize - toggleSpacing
            overlayToggleButton.frame = CGRect(
                x: toggleX,
                y: captureY + (captureButtonSize - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            )
            let cameraSwitchX = captureButton.frame.maxX + toggleSpacing
            cameraSwitchButton.frame = CGRect(
                x: cameraSwitchX,
                y: captureY + (captureButtonSize - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            )
            
            captureButton.isHidden = false
            overlayToggleButton.isHidden = false
            let cameraCount = cameraController?.availableCameras.count ?? 0
            cameraSwitchButton.isHidden = cameraCount <= 1
            retakeButton.isHidden = true
            saveButton.isHidden = true
        } else {
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
            cameraSwitchButton.isHidden = true
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
    
    @objc private func cameraSwitchTapped() {
        guard let cameraController = cameraController else { return }
        let availableCameras = cameraController.availableCameras
        guard availableCameras.count > 1 else { return }
        guard let current = cameraController.currentCamera else { return }
        let currentIndex = availableCameras.firstIndex(where: { $0.uniqueID == current.uniqueID }) ?? 0
        let nextIndex = (currentIndex + 1) % availableCameras.count
        let nextCamera = availableCameras[nextIndex]
        
        cameraController.switchCamera(to: nextCamera)
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
