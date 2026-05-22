//
//  ContentView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var photoStore: PhotoStore
    #if !os(macOS) && !targetEnvironment(macCatalyst)
    @State private var showCamera = false
    #endif
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GalleryView()
                .tabItem {
                    Label("Gallery", systemImage: "photo.on.rectangle")
                }
                .tag(0)
                .environmentObject(photoStore)
            
            Group {
                #if os(macOS) || targetEnvironment(macCatalyst)
                CameraView(onDismiss: {
                    selectedTab = 0
                })
                .environmentObject(photoStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                CameraPlaceholderView()
                    .onAppear {
                        if selectedTab == 1 {
                            showCamera = true
                        }
                    }
                #endif
            }
            .tabItem {
                Label("Camera", systemImage: "camera.fill")
            }
            .tag(1)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
                .environmentObject(photoStore)
        }
        .tint(Color.appAccent)
        .preferredColorScheme(nil)
        #if !os(macOS) && !targetEnvironment(macCatalyst)
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == 1 && oldValue != 1 {
                showCamera = true
            }
        }
        #endif
        #if canImport(UIKit) && !os(macOS) && !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(onDismiss: {
                showCamera = false
                selectedTab = 0
            })
            .environmentObject(photoStore)
        }
        #elseif canImport(AppKit) && !os(macOS) && !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showCamera) {
            CameraView(onDismiss: {
                showCamera = false
                selectedTab = 0
            })
            .environmentObject(photoStore)
            .frame(minWidth: 800, minHeight: 600)
        }
        #endif
    }
}

struct CameraPlaceholderView: View {
    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.06))
                    .frame(width: 160, height: 160)
                Circle()
                    .fill(Color.appAccent.opacity(0.11))
                    .frame(width: 112, height: 112)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(spacing: 10) {
                Text("Ready to Capture")
                    .font(.title3.weight(.bold))
                Text("Tap the Camera tab to take your next photo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.systemGroupedBackground.ignoresSafeArea())
    }
}

#Preview {
    ContentView()
        .environmentObject(PhotoStore())
}

