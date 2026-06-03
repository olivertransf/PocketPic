//
//  ContentView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var photoStore: PhotoStore

    var body: some View {
        #if canImport(UIKit) && !os(macOS) && !targetEnvironment(macCatalyst)
        IOSRootView()
            .environmentObject(photoStore)
        #else
        MacRootView()
            .environmentObject(photoStore)
        #endif
    }
}

#if canImport(UIKit) && !os(macOS) && !targetEnvironment(macCatalyst)
private struct IOSRootView: View {
    @EnvironmentObject private var photoStore: PhotoStore
    @State private var selectedTab = 0
    @State private var showCamera = false

    var body: some View {
        TabView(selection: $selectedTab) {
            GalleryView()
                .environment(\.requestCamera, $showCamera)
                .tabItem {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }
                .tag(0)

            CameraPlaceholderView()
                .onAppear {
                    if selectedTab == 1 {
                        showCamera = true
                    }
                }
                .tabItem {
                    Label("Camera", systemImage: "camera.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .tint(Color.appAccent)
        .onChange(of: selectedTab) { _, newValue in
            if newValue == 1 {
                showCamera = true
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(onDismiss: {
                showCamera = false
                selectedTab = 0
            })
            .environmentObject(photoStore)
        }
    }
}

private struct CameraPlaceholderView: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.systemGroupedBackground)
    }
}
#endif

#if os(macOS) || targetEnvironment(macCatalyst)
private struct MacRootView: View {
    @EnvironmentObject private var photoStore: PhotoStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GalleryView()
                .tabItem {
                    Label("Gallery", systemImage: "photo.on.rectangle")
                }
                .tag(0)
                .environmentObject(photoStore)

            CameraView(onDismiss: {
                selectedTab = 0
            })
            .environmentObject(photoStore)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }
}
#endif

#Preview {
    ContentView()
        .environmentObject(PhotoStore())
}
