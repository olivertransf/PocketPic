//
//  ContentView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var photoStore = PhotoStore()
    @State private var showCamera = false
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GalleryView()
                .tabItem {
                    Label("Gallery", systemImage: "photo.on.rectangle")
                }
                .tag(0)
                .environmentObject(photoStore)
            
            // Camera placeholder view - will trigger camera on tap
            CameraPlaceholderView()
                .tabItem {
                    Label("Camera", systemImage: "camera.fill")
                }
                .tag(1)
                .onAppear {
                    // Automatically open camera when tab is selected
                    if selectedTab == 1 {
                        showCamera = true
                    }
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
                .environmentObject(photoStore)
        }
        .preferredColorScheme(nil)
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == 1 && oldValue != 1 {
                // Only show camera if we're switching TO the camera tab
                showCamera = true
            }
        }
        #if os(macOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(onDismiss: {
                showCamera = false
                selectedTab = 0 // Return to gallery tab
            })
            .environmentObject(photoStore)
        }
        #elseif canImport(AppKit)
        .sheet(isPresented: $showCamera) {
            CameraView(onDismiss: {
                showCamera = false
                selectedTab = 0 // Return to gallery tab
            })
            .environmentObject(photoStore)
            .frame(minWidth: 800, minHeight: 600)
        }
        #endif
    }
}

struct CameraPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.systemGroupedBackground
                .ignoresSafeArea()
            VStack(spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.appAccent.opacity(0.12))
                        .frame(width: 104, height: 104)
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Color.appAccent)
                        .symbolRenderingMode(.hierarchical)
                }
                VStack(spacing: 10) {
                    Text("Capture")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Open this tab to use the camera. Your last gallery photo can appear as a faint overlay for consistent framing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            .padding(36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}

