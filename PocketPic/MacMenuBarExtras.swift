#if os(macOS)
import AppKit
import SwiftUI

enum PocketPicWindowID {
    static let mainApp = "mainApp"
}

/// Menu bar accessory windows default to a single Space; this moves the popover to whichever Space is active when shown.
private final class ActiveSpaceWindowAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window.map(applyActiveSpaceBehavior)
    }

    private func applyActiveSpaceBehavior(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}

private struct ActiveSpaceMenuBarWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ActiveSpaceWindowAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
        }
    }
}

struct PocketPicMenuBarPanel: View {
    @EnvironmentObject private var photoStore: PhotoStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            CameraView(onDismiss: {
                dismiss()
            })
            .frame(width: 360, height: 460)

            Divider()

            HStack(spacing: 12) {
                Button("Open PocketPic…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: PocketPicWindowID.mainApp)
                    dismiss()
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(ActiveSpaceMenuBarWindowConfigurator())
    }
}
#endif
