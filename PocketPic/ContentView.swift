//
//  ContentView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/14/25.
//

import SwiftUI
import AVFoundation

#if os(iOS)
import Photos
#endif

struct ContentView: View {
    @StateObject private var photoManager = PhotoStorageManager()
    @State private var showCamera = false
    @State private var capturedImage: PlatformImage?
    @State private var showingVideoExport = false
    @State private var exportedVideoURL: URL?
    @State private var overlayOpacity: Double = 0.3
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                // Header
                Text("PocketPic")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.top, 40)
                
                Spacer()
                
                // Previous photo preview
                if let previousPhoto = photoManager.previousPhoto {
                    VStack {
                        Text("Previous Photo")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.7))
                        
                        #if os(iOS)
                        Image(uiImage: previousPhoto)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        #elseif os(macOS)
                        Image(nsImage: previousPhoto)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 200)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        #endif
                    }
                    .padding(.horizontal)
                } else {
                    VStack {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.3))
                        Text("No photos yet!\nTake your first selfie")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 8)
                    }
                }
                
                Spacer()
                
                // Opacity slider for overlay
                if photoManager.previousPhoto != nil {
                    VStack {
                        Text("Overlay Opacity: \(Int(overlayOpacity * 100))%")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        Slider(value: $overlayOpacity, in: 0...1)
                            .accentColor(.blue)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 10)
                }
                
                // Buttons
                VStack(spacing: 16) {
                    // Take Photo Button
                    Button(action: {
                        showCamera = true
                    }) {
                        HStack {
                            Image(systemName: "camera.fill")
                                .font(.title2)
                            Text("Take Today's Selfie")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]),
                                         startPoint: .leading,
                                         endPoint: .trailing)
                        )
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                    
                    // Generate Video Button
                    Button(action: {
                        generateVideo()
                    }) {
                        HStack {
                            Image(systemName: "play.rectangle.fill")
                                .font(.title2)
                            Text("Create Video")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 40)
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraOverlayView(
                previousPhoto: photoManager.previousPhoto,
                overlayOpacity: overlayOpacity,
                onCapture: { image in
                    photoManager.savePhoto(image)
                },
                isPresented: $showCamera
            )
        }
        #elseif os(macOS)
        .sheet(isPresented: $showCamera) {
            CameraOverlayView(
                previousPhoto: photoManager.previousPhoto,
                overlayOpacity: overlayOpacity,
                onCapture: { image in
                    photoManager.savePhoto(image)
                },
                isPresented: $showCamera
            )
            .frame(minWidth: 800, minHeight: 600)
        }
        #endif
        .alert("Video Created!", isPresented: $showingVideoExport) {
            Button("Save to Photos") {
                if let url = exportedVideoURL {
                    saveVideoToPhotos(url)
                }
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your time-lapse video has been created successfully!")
        }
    }
    
    private func generateVideo() {
        photoManager.generateVideo { url in
            if let url = url {
                exportedVideoURL = url
                showingVideoExport = true
            }
        }
    }
    
    private func saveVideoToPhotos(_ url: URL) {
        #if os(iOS)
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized else { return }
            
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success {
                    print("Video saved to Photos")
                }
            }
        }
        #elseif os(macOS)
        // On macOS, just show in Finder
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}

#Preview {
    ContentView()
}
