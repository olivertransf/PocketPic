//
//  OverlayView.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct OverlayView: View {
    let image: PlatformImage?
    let isVisible: Bool
    let opacity: Double = 0.35
    
    var body: some View {
        Group {
            if isVisible, let image = image {
                #if canImport(UIKit)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .opacity(opacity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                #elseif canImport(AppKit)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .opacity(opacity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                #endif
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isVisible)
    }
}

#Preview {
    OverlayView(image: nil, isVisible: true)
}

