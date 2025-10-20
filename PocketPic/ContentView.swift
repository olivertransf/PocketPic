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
            
            Button(action: {
                showCamera = true
            }) {
                VStack {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                    Text("Take Selfie")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            .tabItem {
                Label("Camera", systemImage: "camera.fill")
            }
            .tag(1)
            
            ExportView()
                .tabItem {
                    Label("Export", systemImage: "film")
                }
                .tag(2)
                .environmentObject(photoStore)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(3)
                .environmentObject(photoStore)
        }
        .preferredColorScheme(nil) // Adaptive light/dark mode
        .onChange(of: selectedTab) { newTab in
            if newTab == 1 { // Camera tab
                showCamera = true
            }
        }
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


#Preview {
    ContentView()
}

