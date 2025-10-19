//
//  ExportView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI

struct ExportView: View {
    @EnvironmentObject var photoStore: PhotoStore
    @StateObject private var exportViewModel = ExportViewModel()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                if photoStore.photos.isEmpty {
                    // Empty state
                    Spacer()
                    
                    Image(systemName: "film")
                        .font(.system(size: 70))
                        .foregroundColor(.secondary)
                    
                    Text("No Photos to Export")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Take some selfies first to create your montage")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Spacer()
                } else {
                    Spacer()
                    
                    // Preview info
                    VStack(spacing: 15) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 60))
                            .foregroundColor(.primary)
                        
                        Text("\(photoStore.photos.count) Photos")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Create a time-lapse video from your selfies")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        // FPS Selection
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Frame Rate")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            HStack(spacing: 12) {
                                ForEach(exportViewModel.availableFPSOptions, id: \.self) { fps in
                                    Button(action: {
                                        exportViewModel.selectedFPS = fps
                                    }) {
                                        Text("\(fps)")
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.medium)
                                            .foregroundColor(exportViewModel.selectedFPS == fps ? .white : .primary)
                                            .frame(width: 44, height: 44)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(exportViewModel.selectedFPS == fps ? Color.blue : Color.secondary.opacity(0.2))
                                            )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                            Text("FPS")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                        
                        // Video details
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "film.fill")
                                Text("\(exportViewModel.selectedFPS) frames per second")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            HStack {
                                Image(systemName: "clock.fill")
                                Text("Duration: ~\(String(format: "%.1f", Double(photoStore.photos.count) / Double(exportViewModel.selectedFPS)))s")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                            HStack {
                                Image(systemName: "video.fill")
                                Text("1920x1080 H.264")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)
                    }
                    
                    Spacer()
                    
                    // Export button
                    if exportViewModel.isExporting {
                        VStack(spacing: 15) {
                            ProgressView(value: exportViewModel.exportProgress) {
                                Text("Creating Video...")
                                    .font(.headline)
                            }
                            .progressViewStyle(.linear)
                            
                            Text("\(Int(exportViewModel.exportProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 40)
                        .padding(.bottom, 40)
                    } else {
                        Button(action: {
                            Task {
                                await exportViewModel.exportVideo(photos: photoStore.photos, photoStore: photoStore)
                            }
                        }) {
                            Label("Export Montage", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .cornerRadius(12)
                                .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.horizontal, 40)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Export")
            .alert("Error", isPresented: .constant(exportViewModel.errorMessage != nil)) {
                Button("OK") {
                    exportViewModel.errorMessage = nil
                }
            } message: {
                if let error = exportViewModel.errorMessage {
                    Text(error)
                }
            }
            .sheet(isPresented: $exportViewModel.showShareSheet) {
                if let videoURL = exportViewModel.exportedVideoURL {
                    ShareSheet(items: [videoURL])
                }
            }
        }
    }
}

// Share Sheet for iOS/macOS
#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed
    }
}
#elseif canImport(AppKit)
struct ShareSheet: NSViewRepresentable {
    let items: [Any]
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // For macOS, we can use NSSharingServicePicker
        // But for simplicity, we'll just let the user manually save
    }
}
#endif

#Preview {
    ExportView()
        .environmentObject(PhotoStore())
}

