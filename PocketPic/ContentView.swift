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
                    Label("Library", systemImage: "photo.on.rectangle.angled")
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
        PocketPicGroupedBackground()
    }
}
#endif

#if os(macOS) || targetEnvironment(macCatalyst)
private enum MacSection: String, CaseIterable, Identifiable {
    case library
    case camera
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .camera: "Camera"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .library: "photo.on.rectangle.angled"
        case .camera: "camera.fill"
        case .settings: "gearshape"
        }
    }
}

private struct MacRootView: View {
    @EnvironmentObject private var photoStore: PhotoStore
    @State private var selection: MacSection? = .library
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(MacSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("PocketPic")
            .listStyle(.sidebar)
            .frame(minWidth: 200)
        } detail: {
            macDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.automatic)
        .tint(Color.appAccent)
        .onChange(of: selection) { _, newSelection in
            columnVisibility = newSelection == .camera ? .detailOnly : .all
        }
    }

    @ViewBuilder
    private var macDetail: some View {
        switch selection ?? .library {
        case .library:
            GalleryView()
                .environmentObject(photoStore)
        case .camera:
            NavigationStack {
                CameraView(
                    onDismiss: { selection = .library },
                    embeddedInAppChrome: true
                )
                .environmentObject(photoStore)
                .navigationTitle("Camera")
                #if os(macOS)
                .navigationSubtitle("Take your daily photo")
                #endif
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            selection = .library
                        } label: {
                            Label("Library", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            selection = .settings
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .toolbarBackground(.visible, for: .windowToolbar)
            }
            .background(Color.black)
        case .settings:
            SettingsView()
                .environmentObject(photoStore)
                .background(Color.systemGroupedBackground)
        }
    }
}
#endif

#Preview {
    ContentView()
        .environmentObject(PhotoStore())
}
