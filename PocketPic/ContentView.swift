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
        VStack(spacing: 20) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Color.appAccent)

            VStack(spacing: 6) {
                Text("Open the Camera tab to capture a photo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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

