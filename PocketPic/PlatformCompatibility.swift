//
//  PlatformCompatibility.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

// MARK: - Shared Colors

extension Color {
    /// Primary tint used throughout the app.
    static var appAccent: Color { Color(red: 0.45, green: 0.25, blue: 0.88) }

    static var systemBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.clear
        #endif
    }

    static var systemGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.clear
        #endif
    }
}
