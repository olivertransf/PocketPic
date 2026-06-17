//
//  PocketPicUI.swift
//  PocketPic
//
//  Shared visual language across iOS and macOS.
//

import SwiftUI

enum PocketPicDesign {
    static let gridSpacing: CGFloat = 1
    static let sheetRadius: CGFloat = 20
    static let contentPadding: CGFloat = 16
    #if os(macOS)
    static let libraryHeaderInset: CGFloat = 16
    #else
    static let libraryHeaderInset: CGFloat = 16
    #endif
}

// MARK: - Surfaces

struct PocketPicGroupedBackground: View {
    var body: some View {
        Color.systemGroupedBackground.ignoresSafeArea()
    }
}

// MARK: - Settings helpers

struct PocketPicSettingsForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
        Form { content() }
            .formStyle(.grouped)
        #else
        Form { content() }
            .formStyle(.grouped)
        #endif
    }
}

struct PocketPicSettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PocketPicSettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var suffix: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(suffix(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .font(.subheadline)
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Sheets & modals

extension View {
    func pocketPicSheetChrome() -> some View {
        self
            #if canImport(UIKit)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(PocketPicDesign.sheetRadius)
            #endif
    }
}

struct PocketPicModalHeader: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    init(_ title: String, subtitle: String? = nil, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
