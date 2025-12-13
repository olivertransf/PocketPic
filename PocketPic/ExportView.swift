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
            ScrollView {
                VStack(spacing: 24) {
                    if photoStore.photos.isEmpty {
                        // Modern empty state
                        VStack(spacing: 24) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.1), .purple.opacity(0.1)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 120, height: 120)
                                
                                Image(systemName: "film")
                                    .font(.system(size: 50))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                            
                            VStack(spacing: 8) {
                                Text("No Photos to Export")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                
                                Text("Take some selfies first to create your montage")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.top, 100)
                    } else {
                        // Preview info card
                        VStack(spacing: 20) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.blue.opacity(0.2), .purple.opacity(0.2)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 100, height: 100)
                                
                                Image(systemName: "film.stack")
                                    .font(.system(size: 45))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                            
                            VStack(spacing: 4) {
                                Text("\(photoStore.photos.count)")
                                    .font(.system(size: 48, weight: .bold, design: .rounded))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                
                                Text(photoStore.photos.count == 1 ? "Photo" : "Photos")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("Create a time-lapse video from your selfies")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.systemBackground)
                                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
                        )
                        .padding(.horizontal)
                        
                        // FPS Selection card
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Frame Rate")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            HStack(spacing: 12) {
                                ForEach(exportViewModel.availableFPSOptions, id: \.self) { fps in
                                    Button(action: {
                                        withAnimation(.spring(response: 0.3)) {
                                            exportViewModel.selectedFPS = fps
                                        }
                                    }) {
                                        Text("\(fps)")
                                            .font(.system(.body, design: .monospaced))
                                            .fontWeight(.semibold)
                                            .foregroundColor(exportViewModel.selectedFPS == fps ? .white : .primary)
                                            .frame(width: 50, height: 50)
                                            .background(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .fill(
                                                        exportViewModel.selectedFPS == fps ?
                                                        LinearGradient(
                                                            colors: [.blue, .purple],
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        ) :
                                                        LinearGradient(
                                                            colors: [Color.secondary.opacity(0.1), Color.secondary.opacity(0.1)],
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        )
                                                    )
                                            )
                                            .shadow(
                                                color: exportViewModel.selectedFPS == fps ? .blue.opacity(0.3) : .clear,
                                                radius: exportViewModel.selectedFPS == fps ? 8 : 0,
                                                x: 0,
                                                y: exportViewModel.selectedFPS == fps ? 4 : 0
                                            )
                                            .scaleEffect(exportViewModel.selectedFPS == fps ? 1.05 : 1.0)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                            Text("Frames per second")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.systemBackground)
                                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                        )
                        .padding(.horizontal)
                        
                        // Video details card
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: "film.fill")
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 20)
                                Text("\(exportViewModel.selectedFPS) frames per second")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            
                            HStack(spacing: 12) {
                                Image(systemName: "clock.fill")
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 20)
                                Text("Duration: ~\(String(format: "%.1f", Double(photoStore.photos.count) / Double(exportViewModel.selectedFPS)))s")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            
                            HStack(spacing: 12) {
                                Image(systemName: "video.fill")
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 20)
                                Text("1080x1920 Portrait H.264")
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.systemBackground)
                                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                        )
                        .padding(.horizontal)
                        
                        // Export button
                        if exportViewModel.isExporting {
                            VStack(spacing: 16) {
                                ProgressView(value: exportViewModel.exportProgress) {
                                    HStack {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                        Text("Creating Video...")
                                            .font(.headline)
                                    }
                                }
                                .progressViewStyle(.linear)
                                .tint(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                
                                Text("\(Int(exportViewModel.exportProgress * 100))%")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.systemBackground)
                                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
                            )
                            .padding(.horizontal)
                            .padding(.top, 8)
                        } else {
                            Button(action: {
                                Task {
                                    await exportViewModel.exportVideo(photos: photoStore.photos, photoStore: photoStore)
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 18, weight: .semibold))
                                    Text("Export Montage")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .cornerRadius(16)
                                .shadow(color: .blue.opacity(0.4), radius: 12, x: 0, y: 6)
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical)
            }
            .background(Color.systemGroupedBackground)
            .navigationTitle("Export")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.large)
            #endif
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

#Preview {
    ExportView()
        .environmentObject(PhotoStore())
}

