//
//  PlatformCompatibility.swift
//  PocketPic
//
//  Created by Oliver Tran on 10/18/25.
//

import Foundation

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif
