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
    @State private var lastPhotoPreview: PlatformImage?
    @State private var isSaving = false
    @State private var overlayLoadToken = UUID()
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
            lastPhotoImage: lastPhotoPreview,
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
            resetCaptureState()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            orientation = UIDevice.current.orientation
            cameraController.preferredPosition = photoStore.defaultCameraPosition == "back" ? .back : .front
            overlayLoadToken = UUID()
            cameraController.startSession()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            cameraController.stopSession()
        }
        #else
        .onAppear {
            resetCaptureState()
            cameraController.preferredPosition = photoStore.defaultCameraPosition == "back" ? .back : .front
            overlayLoadToken = UUID()
            cameraController.startSession()
        }
        .onDisappear {
            cameraController.stopSession()
        }
        #endif
        .task(id: overlayLoadToken) {
            guard let last = photoStore.getLastPhoto() else {
                lastPhotoPreview = nil
                return
            }
            #if os(macOS)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            #else
            let scale = UIScreen.main.scale
            #endif
            lastPhotoPreview = await photoStore.loadThumbnail(for: last, pointWidth: 480, displayScale: scale)
        }
        .onChange(of: photoStore.photos.count) { _, _ in
            overlayLoadToken = UUID()
        }
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
        guard let image = capturedImage, !isSaving else {
            if capturedImage == nil {
                print("Error: No captured image to save")
            }
            return
        }

        isSaving = true
        Task {
            let saved = await photoStore.savePhoto(image)
            await MainActor.run {
                isSaving = false
                guard saved else { return }
                onDismiss?() ?? dismiss()
            }
        }
    }

    private func resetCaptureState() {
        capturedImage = nil
        showCapturedImage = false
        showOverlay = false
        isSaving = false
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

    /// The camera position to select on first launch / camera discovery.
    var preferredPosition: AVCaptureDevice.Position = .front

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
        let allDevices = discoverySession.devices.filter { $0.hasMediaType(.video) }

        // Keep one front camera (prefer wide angle) and one back camera (prefer wide angle)
        // This prevents cycling through multiple front cameras on iPad
        let frontCamera = allDevices.first(where: { $0.position == .front && $0.deviceType == .builtInWideAngleCamera })
            ?? allDevices.first(where: { $0.position == .front })
        let backCamera = allDevices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })
            ?? allDevices.first(where: { $0.position == .back })
        let discoveredCameras = [frontCamera, backCamera].compactMap { $0 }
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
            let _ = self.currentCamera
            
            self.availableCameras = discoveredCameras
            
            let firstCamera = discoveredCameras.first
            
            if self.currentCamera == nil || !(discoveredCameras.contains { $0.uniqueID == self.currentCamera?.uniqueID }) {
                let preferred = discoveredCameras.first(where: { $0.position == self.preferredPosition })
                self.currentCamera = preferred ?? firstCamera
                print("Selected camera: \(self.currentCamera?.localizedName ?? "none")")
            }
            
            if !hadCameras && !discoveredCameras.isEmpty && self.currentCamera != nil {
                if !self.isSetup {
                    self.configQueue.async { [weak self] in
                        guard let self = self else { return }
                        self.setupCameraSync()
                        if self.isSetup && !self.captureSession.isRunning {
                            self.captureSession.startRunning()
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
            self.discoverCameras()
            if let newCamera = self.availableCameras.first {
                self.switchCamera(to: newCamera)
            } else {
                self.currentCamera = nil
            }
        }
    }
    
    func switchCamera(to device: AVCaptureDevice, completion: (() -> Void)? = nil) {
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
                }

                device.unlockForConfiguration()
            } catch {
                print("Error switching camera: \(error)")
            }

            self.captureSession.commitConfiguration()
            self.isConfiguring = false

            DispatchQueue.main.async {
                self.currentCamera = device
                completion?()
            }
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

        configQueue.async { [weak self] in
            guard let self = self else { return }
            if self.availableCameras.isEmpty { return }
            if !self.isSetup {
                self.setupCameraSync()
            }
            if self.isSetup && !self.captureSession.isRunning && !self.isConfiguring {
                self.captureSession.startRunning()
            }
        }
    }
    
    func updatePhotoOutputRotationAngle(_ angle: CGFloat) {
        if let connection = photoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    #if canImport(UIKit)
    func updatePhotoOutputOrientation(_ orientation: AVCaptureVideoOrientation) {
        guard let connection = photoOutput.connection(with: .video),
              connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = orientation
    }
    #endif
    
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
        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        } else if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }
        #else
        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        } else if captureSession.canSetSessionPreset(.hd1920x1080) {
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
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
                #else
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
                #endif
            }
            camera.unlockForConfiguration()
            isSetup = true
        } catch {
            print("Error setting up camera: \(error)")
            captureSession.commitConfiguration()
            isConfiguring = false
            camera.unlockForConfiguration()
        }
    }
    
    func stopSession() {
        configQueue.async { [weak self] in
            guard let self else { return }
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
    
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image: PlatformImage?
        if let imageData = photo.fileDataRepresentation() {
            #if canImport(UIKit)
            image = UIImage(data: imageData)
            #elseif canImport(AppKit)
            image = NSImage(data: imageData)
            #else
            image = nil
            #endif
        } else {
            image = nil
        }

        let completion = captureCompletion
        captureCompletion = nil
        DispatchQueue.main.async {
            completion?(image)
        }
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
        container.onRetake = {
            self.$capturedImage.wrappedValue = nil
            self.$showCapturedImage.wrappedValue = false
        }
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
        uiView.lastPhotoImage = lastPhotoImage
        uiView.cameraController = cameraController
        uiView.updateUI()
    }
}

#elseif canImport(AppKit)
struct CameraViewWrapper: View {
    @ObservedObject var cameraController: CameraController
    @Binding var capturedImage: PlatformImage?
    @Binding var showCapturedImage: Bool
    @Binding var showOverlay: Bool
    let lastPhotoImage: PlatformImage?
    let overlayOpacity: Double
    let onDismiss: () -> Void
    let onCapture: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MacCameraPreviewRepresentable(session: cameraController.captureSession)
                    .background(Color.black)

                if showOverlay, let lastPhotoImage {
                    Image(nsImage: lastPhotoImage)
                        .resizable()
                        .scaledToFill()
                        .opacity(overlayOpacity)
                        .allowsHitTesting(false)
                }

                if showCapturedImage, let capturedImage {
                    Image(nsImage: capturedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 22, height: 22)
                        .background(.black.opacity(0.28), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            MacCameraControlBar(
                cameraController: cameraController,
                showCapturedImage: showCapturedImage,
                showOverlay: showOverlay,
                hasOverlayPhoto: lastPhotoImage != nil,
                onCapture: onCapture,
                onSave: onSave,
                onRetake: {
                    capturedImage = nil
                    showCapturedImage = false
                },
                onToggleOverlay: { showOverlay.toggle() },
                onSwitchCamera: switchCamera
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func switchCamera() {
        let cameras = cameraController.availableCameras
        guard cameras.count > 1, let current = cameraController.currentCamera else { return }
        let currentIndex = cameras.firstIndex(where: { $0.uniqueID == current.uniqueID }) ?? 0
        let nextIndex = (currentIndex + 1) % cameras.count
        cameraController.switchCamera(to: cameras[nextIndex])
    }
}

private struct MacCameraControlBar: View {
    @ObservedObject var cameraController: CameraController
    let showCapturedImage: Bool
    let showOverlay: Bool
    let hasOverlayPhoto: Bool
    let onCapture: () -> Void
    let onSave: () -> Void
    let onRetake: () -> Void
    let onToggleOverlay: () -> Void
    let onSwitchCamera: () -> Void

    private var canSwitchCamera: Bool {
        cameraController.availableCameras.count > 1
    }

    var body: some View {
        Group {
            if showCapturedImage {
                HStack(spacing: 12) {
                    Button("Retake", action: onRetake)
                        .keyboardShortcut(.cancelAction)

                    Spacer(minLength: 0)

                    Button("Use Photo", action: onSave)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 12) {
                    Button(action: onToggleOverlay) {
                        Image(systemName: showOverlay ? "person.crop.rectangle.stack.fill" : "person.crop.rectangle.stack")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("Show last photo overlay")
                    .disabled(!hasOverlayPhoto)
                    .opacity(hasOverlayPhoto ? 1 : 0.35)

                    Spacer(minLength: 0)

                    Button(action: onCapture) {
                        ZStack {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 2.5)
                                .frame(width: 48, height: 48)
                            Circle()
                                .fill(Color.primary.opacity(0.88))
                                .frame(width: 38, height: 38)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Capture photo")
                    .accessibilityLabel("Capture photo")

                    Spacer(minLength: 0)

                    Button(action: onSwitchCamera) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.borderless)
                    .help("Switch camera")
                    .disabled(!canSwitchCamera)
                    .opacity(canSwitchCamera ? 1 : 0)
                    .frame(width: 28)
                }
                .controlSize(.large)
                .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(.bar)
    }
}

private struct MacCameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> MacCameraPreviewHostView {
        let view = MacCameraPreviewHostView()
        view.attach(session: session)
        return view
    }

    func updateNSView(_ nsView: MacCameraPreviewHostView, context: Context) {
        nsView.attach(session: session)
    }
}

private final class MacCameraPreviewHostView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(session: AVCaptureSession) {
        if previewLayer?.session === session { return }
        previewLayer?.removeFromSuperlayer()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer?.insertSublayer(layer, at: 0)
        previewLayer = layer
        needsLayout = true
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
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
    private var orientationUpdateWorkItem: DispatchWorkItem?
    // Rotation coordinator (iOS 17+) — stored as Any to avoid @available on properties
    private var _rotationCoordinator: Any?
    private var _rotationObservation: Any?
    // Observes AVCaptureSession running state to set up orientation after session is ready
    private var sessionRunningObserver: NSObjectProtocol?

    var onDismiss: (() -> Void)?
    var onCapture: (() -> Void)?
    var onSave: (() -> Void)?
    var onRetake: (() -> Void)?
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
        if let obs = sessionRunningObserver {
            NotificationCenter.default.removeObserver(obs)
        }
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
            self.updateFrame()
            if #unavailable(iOS 17.0) {
                self.applyLegacyOrientation()
            }
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        orientationUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }
    
    func setupCamera(cameraController: CameraController) {
        self.cameraController = cameraController

        // Remove old session observer before attaching new one
        if let old = sessionRunningObserver {
            NotificationCenter.default.removeObserver(old)
        }

        let layer = AVCaptureVideoPreviewLayer(session: cameraController.captureSession)
        layer.videoGravity = .resizeAspectFill
        self.layer.insertSublayer(layer, at: 0)
        self.previewLayer = layer

        // When the session starts running we know the connection is live — safe
        // to set up the rotation coordinator and apply initial orientation.
        sessionRunningObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionDidStartRunning,
            object: cameraController.captureSession,
            queue: .main
        ) { [weak self] _ in
            self?.onSessionStartedRunning()
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
            self?.previewLayer?.isHidden = false
        }
    }

    /// Called on main thread once the capture session is actually running.
    private func onSessionStartedRunning() {
        setupCameraOrientation()
        if #available(iOS 17.0, *) {
            // RotationCoordinator handles it via KVO
        } else {
            applyLegacyOrientation()
        }
    }

    private func setupCameraOrientation() {
        if #available(iOS 17.0, *) {
            setupRotationCoordinator()
        }
    }

    @available(iOS 17.0, *)
    private func setupRotationCoordinator() {
        _rotationObservation = nil
        _rotationCoordinator = nil

        guard let device = cameraController?.currentCamera,
              let layer = previewLayer else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        _rotationCoordinator = coordinator

        applyRotation(from: coordinator)

        _rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coord, _ in
            DispatchQueue.main.async {
                self?.applyRotation(from: coord)
            }
        }
    }

    @available(iOS 17.0, *)
    private func applyRotation(from coordinator: AVCaptureDevice.RotationCoordinator) {
        previewLayer?.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        cameraController?.updatePhotoOutputRotationAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
    }

    private func applyLegacyOrientation() {
        guard #unavailable(iOS 17.0) else { return }
        let deviceOrientation = UIDevice.current.orientation
        let videoOrientation: AVCaptureVideoOrientation
        switch deviceOrientation {
        case .landscapeLeft:        videoOrientation = .landscapeRight
        case .landscapeRight:       videoOrientation = .landscapeLeft
        case .portraitUpsideDown:   videoOrientation = .portraitUpsideDown
        default:                    videoOrientation = .portrait
        }
        previewLayer?.connection?.videoOrientation = videoOrientation
        cameraController?.updatePhotoOutputOrientation(videoOrientation)
    }
    
    
    private func setupUI() {
        backgroundColor = .black
        
        overlayImageView = UIImageView()
        overlayImageView.contentMode = .scaleAspectFill
        overlayImageView.clipsToBounds = true
        overlayImageView.alpha = 0.4
        overlayImageView.isHidden = true
        overlayImageView.isUserInteractionEnabled = false
        addSubview(overlayImageView)

        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        imageView.isHidden = true
        addSubview(imageView)
        
        // Close button — glass circle with xmark
        closeButton = UIButton(type: .system)
        let xmarkConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xmarkConfig), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 0.12, alpha: 0.72)
        closeButton.layer.cornerRadius = 22
        closeButton.layer.cornerCurve = .continuous
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)
        
        // Overlay toggle — glass pill button
        overlayToggleButton = UIButton(type: .system)
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        overlayToggleButton.setImage(UIImage(systemName: "person.crop.rectangle.stack", withConfiguration: symbolConfig), for: .normal)
        overlayToggleButton.setImage(UIImage(systemName: "person.crop.rectangle.stack.fill", withConfiguration: symbolConfig), for: .selected)
        overlayToggleButton.tintColor = .white
        overlayToggleButton.backgroundColor = UIColor(white: 0.12, alpha: 0.72)
        overlayToggleButton.layer.cornerRadius = 27
        overlayToggleButton.layer.cornerCurve = .continuous
        overlayToggleButton.addTarget(self, action: #selector(overlayToggleTapped), for: .touchUpInside)
        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            overlayToggleButton.configuration = cfg
        }
        addSubview(overlayToggleButton)

        // Camera flip — glass circle button
        cameraSwitchButton = UIButton(type: .system)
        let camSymbolConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        cameraSwitchButton.setImage(UIImage(systemName: "camera.rotate", withConfiguration: camSymbolConfig), for: .normal)
        cameraSwitchButton.tintColor = .white
        cameraSwitchButton.backgroundColor = UIColor(white: 0.12, alpha: 0.72)
        cameraSwitchButton.layer.cornerRadius = 27
        cameraSwitchButton.layer.cornerCurve = .continuous
        cameraSwitchButton.addTarget(self, action: #selector(cameraSwitchTapped), for: .touchUpInside)
        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            cameraSwitchButton.configuration = cfg
        }
        addSubview(cameraSwitchButton)

        // Shutter button — classic iOS concentric-circle style
        captureButton = UIButton(type: .custom)
        captureButton.backgroundColor = .clear
        captureButton.layer.cornerRadius = 41
        captureButton.layer.borderWidth = 4
        captureButton.layer.borderColor = UIColor.white.cgColor
        // Inner white fill sublayer
        let shutterInner = CALayer()
        shutterInner.backgroundColor = UIColor.white.cgColor
        shutterInner.cornerRadius = 33
        shutterInner.frame = CGRect(x: 8, y: 8, width: 66, height: 66)
        captureButton.layer.insertSublayer(shutterInner, at: 0)
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        addSubview(captureButton)

        // Retake — glass dark pill
        retakeButton = UIButton(type: .system)
        retakeButton.setTitle("Retake", for: .normal)
        retakeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retakeButton.setTitleColor(.white, for: .normal)
        retakeButton.backgroundColor = UIColor(white: 0.14, alpha: 0.80)
        retakeButton.layer.cornerRadius = 14
        retakeButton.layer.cornerCurve = .continuous
        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)
        addSubview(retakeButton)

        // Use Photo — accent-colored pill
        saveButton = UIButton(type: .system)
        saveButton.setTitle("Use Photo", for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 1)
        saveButton.layer.cornerRadius = 14
        saveButton.layer.cornerCurve = .continuous
        saveButton.layer.shadowColor = UIColor(red: 0.051, green: 0.580, blue: 0.533, alpha: 1).cgColor
        saveButton.layer.shadowOpacity = 0.45
        saveButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        saveButton.layer.shadowRadius = 10
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        addSubview(saveButton)
        
        updateUI()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrame()
        updateButtonPositions()
    }
    
    
    private func updateFrame() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateFrame() }
            return
        }
        previewLayer?.frame = bounds
        imageView.frame = bounds
        overlayImageView.frame = bounds
    }
    
    private func updateButtonPositions() {
        let safeInsets = safeAreaInsets
        let sideButtonSize: CGFloat = 54   // overlay toggle & camera flip
        let shutterSize: CGFloat = 82      // outer ring diameter
        let closeSize: CGFloat = 44
        let margin: CGFloat = 28

        let isLandscape = bounds.width > bounds.height

        // Close button — top-leading
        closeButton.frame = CGRect(
            x: safeInsets.left + margin,
            y: safeInsets.top + margin,
            width: closeSize,
            height: closeSize
        )

        if !showCapturedImage {
            if isLandscape {
                // Right column: camera-flip, overlay-toggle, shutter (top → bottom)
                let col = bounds.width - safeInsets.right - margin - shutterSize
                let centerY = bounds.height / 2

                cameraSwitchButton.frame = CGRect(
                    x: col + (shutterSize - sideButtonSize) / 2,
                    y: centerY - shutterSize / 2 - 20 - sideButtonSize,
                    width: sideButtonSize, height: sideButtonSize
                )
                overlayToggleButton.frame = CGRect(
                    x: col + (shutterSize - sideButtonSize) / 2,
                    y: centerY - sideButtonSize / 2,
                    width: sideButtonSize, height: sideButtonSize
                )
                captureButton.frame = CGRect(
                    x: col,
                    y: centerY + 20 + sideButtonSize / 2,
                    width: shutterSize, height: shutterSize
                )
            } else {
                // Bottom row: overlay-toggle | shutter | camera-flip
                let bottomY = bounds.height - safeInsets.bottom - margin - shutterSize
                let cx = (bounds.width - shutterSize) / 2

                captureButton.frame = CGRect(x: cx, y: bottomY, width: shutterSize, height: shutterSize)

                let sideY = bottomY + (shutterSize - sideButtonSize) / 2
                overlayToggleButton.frame = CGRect(
                    x: cx - 44 - sideButtonSize,
                    y: sideY,
                    width: sideButtonSize, height: sideButtonSize
                )
                cameraSwitchButton.frame = CGRect(
                    x: cx + shutterSize + 44,
                    y: sideY,
                    width: sideButtonSize, height: sideButtonSize
                )
            }
            captureButton.isHidden = false
            overlayToggleButton.isHidden = false
            let cameraCount = cameraController?.availableCameras.count ?? 0
            cameraSwitchButton.isHidden = cameraCount <= 1
            retakeButton.isHidden = true
            saveButton.isHidden = true
        } else {
            let buttonHeight: CGFloat = 52
            let buttonWidth: CGFloat = 130
            let spacing: CGFloat = 16

            if isLandscape {
                let col = bounds.width - safeInsets.right - margin - buttonWidth
                let startY = (bounds.height - buttonHeight * 2 - spacing) / 2
                retakeButton.frame = CGRect(x: col, y: startY, width: buttonWidth, height: buttonHeight)
                saveButton.frame = CGRect(x: col, y: startY + buttonHeight + spacing, width: buttonWidth, height: buttonHeight)
            } else {
                let totalW = buttonWidth * 2 + spacing
                let startX = (bounds.width - totalW) / 2
                let bY = bounds.height - safeInsets.bottom - margin - buttonHeight
                retakeButton.frame = CGRect(x: startX, y: bY, width: buttonWidth, height: buttonHeight)
                saveButton.frame = CGRect(x: startX + buttonWidth + spacing, y: bY, width: buttonWidth, height: buttonHeight)
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
            
            if self.showCapturedImage, let image = self.capturedImage {
                self.imageView.image = image
                self.imageView.isHidden = false
                self.previewLayer?.isHidden = true
                self.overlayImageView.isHidden = true
            } else {
                self.imageView.isHidden = true
                self.previewLayer?.isHidden = false
                let shouldShowOverlay = self.showOverlay && self.lastPhotoImage != nil
                self.overlayImageView.isHidden = !shouldShowOverlay
                self.overlayToggleButton.isSelected = self.showOverlay
            }
        }
    }

    @objc private func closeTapped() {
        onDismiss?()
    }

    @objc private func captureTapped() {
        // Classic spring press feel
        UIView.animate(withDuration: 0.08, delay: 0, options: .curveEaseIn) {
            self.captureButton.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        } completion: { _ in
            UIView.animate(
                withDuration: 0.28, delay: 0,
                usingSpringWithDamping: 0.52,
                initialSpringVelocity: 0.6
            ) {
                self.captureButton.transform = .identity
            }
        }
        onCapture?()
    }

    @objc private func overlayToggleTapped() {
        onToggleOverlay?()
    }
    
    @objc private func cameraSwitchTapped() {
        guard let cameraController = cameraController else { return }
        let cameras = cameraController.availableCameras
        guard cameras.count > 1, let current = cameraController.currentCamera else { return }
        let currentIndex = cameras.firstIndex(where: { $0.uniqueID == current.uniqueID }) ?? 0
        let nextIndex = (currentIndex + 1) % cameras.count
        cameraController.switchCamera(to: cameras[nextIndex]) { [weak self] in
            // Camera switch has committed — safe to re-bind the rotation coordinator
            self?.setupCameraOrientation()
            if #available(iOS 17.0, *) {
                // RotationCoordinator KVO takes over
            } else {
                self?.applyLegacyOrientation()
            }
        }
    }

    @objc private func retakeTapped() {
        onRetake?()
    }

    @objc private func saveTapped() {
        onSave?()
    }

    private func updateOverlayOpacity() {
        overlayImageView?.alpha = CGFloat(overlayOpacity)
    }
}
#endif
