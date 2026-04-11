//
//  PocketPicApp.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/14/25.
//

import SwiftUI

@main
struct PocketPicApp: App {
    @StateObject private var photoStore = PhotoStore()

    var body: some Scene {
        #if os(macOS)
        MenuBarExtra("PocketPic", systemImage: "camera.viewfinder") {
            PocketPicMenuBarPanel()
                .environmentObject(photoStore)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: PocketPicWindowID.mainApp) {
            ContentView()
                .environmentObject(photoStore)
                .tint(Color.appAccent)
        }
        .defaultSize(width: 960, height: 720)
        .defaultLaunchBehavior(.suppressed)
        #else
        WindowGroup {
            ContentView()
                .environmentObject(photoStore)
                .tint(Color.appAccent)
        }
        #endif
    }
}
