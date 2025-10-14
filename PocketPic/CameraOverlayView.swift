//
//  CameraOverlayView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/14/25.
//

import SwiftUI
import AVFoundation
import Combine

struct CameraOverlayView: View {
    let previousPhoto: PlatformImage?
    let overlayOpacity: Double
    let onCapture: (PlatformImage) -> Void
    @Binding var isPresented: Bool
    
    @StateObject private var camera = CameraModel()
    
    var body: some View {
        ZStack {
            // Camera preview
            CameraPreview(camera: camera)
                .ignoresSafeArea(.all)
            
            // Previous photo overlay
            if let previousPhoto = previousPhoto {
                #if os(iOS)
                Image(uiImage: previousPhoto)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea(.all)
                    .opacity(overlayOpacity)
                #elseif os(macOS)
                Image(nsImage: previousPhoto)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea(.all)
                    .opacity(overlayOpacity)
                #endif
            }
            
            // UI Controls
            VStack {
                // Top bar
                HStack {
                    Button(action: {
                        isPresented = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
                    
                    Spacer()
                }
                
                Spacer()
                
                // Guide text
                if previousPhoto != nil {
                    Text("Align your face with the overlay")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                }
                
                // Capture button
                Button(action: {
                    camera.capturePhoto { image in
                        if let image = image {
                            onCapture(image)
                            isPresented = false
                        }
                    }
                }) {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 4)
                        .background(Circle().fill(Color.white.opacity(0.3)))
                        .frame(width: 70, height: 70)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            camera.checkPermissions()
        }
    }
}

class CameraModel: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var alert = false
    @Published var output = AVCapturePhotoOutput()
    
    private var captureCompletion: ((PlatformImage?) -> Void)?
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUp()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] status in
                if status {
                    self?.setUp()
                }
            }
        default:
            alert = true
        }
    }
    
    func setUp() {
        do {
            session.beginConfiguration()
            
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                return
            }
            
            let input = try AVCaptureDeviceInput(device: device)
            
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            
            session.commitConfiguration()
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        } catch {
            print("Camera setup error: \(error.localizedDescription)")
        }
    }
    
    func capturePhoto(completion: @escaping (PlatformImage?) -> Void) {
        captureCompletion = completion
        
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            captureCompletion?(nil)
            return
        }
        
        guard let imageData = photo.fileDataRepresentation() else {
            captureCompletion?(nil)
            return
        }
        
        #if os(iOS)
        guard let image = UIImage(data: imageData) else {
            captureCompletion?(nil)
            return
        }
        captureCompletion?(image)
        #elseif os(macOS)
        guard let image = NSImage(data: imageData) else {
            captureCompletion?(nil)
            return
        }
        captureCompletion?(image)
        #endif
    }
}

#if os(iOS)
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraModel
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = UIScreen.main.bounds
        
        view.layer.addSublayer(previewLayer)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = UIScreen.main.bounds
        }
    }
}
#elseif os(macOS)
struct CameraPreview: NSViewRepresentable {
    @ObservedObject var camera: CameraModel
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        view.wantsLayer = true
        view.layer = previewLayer
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Preview layer updates automatically
    }
}
#endif

