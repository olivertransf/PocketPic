//
//  PocketPicApp.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/14/25.
//

import SwiftUI

@main
struct PocketPicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color.appAccent)
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 720)
        #endif
    }
}
