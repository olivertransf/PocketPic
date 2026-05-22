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
        if let window = nsView.window {
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}

/// MenuBarExtra `.window` content often stays mounted when the popover closes, so SwiftUI `onDisappear`
/// does not reliably stop the camera or reset capture state. Observe the hosting window instead.
private final class MenuBarPanelLifecycleAnchorView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

private struct MenuBarPanelLifecycleObserver: NSViewRepresentable {
    let onOpen: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen, onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = MenuBarPanelLifecycleAnchorView()
        anchor.onWindowChanged = { window in
            context.coordinator.setWindow(window)
        }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private let onOpen: () -> Void
        private let onClose: () -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var isOpen = false

        init(onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.onOpen = onOpen
            self.onClose = onClose
        }

        func setWindow(_ window: NSWindow?) {
            guard window !== self.window else { return }
            removeObservers()
            self.window = window
            guard let window else { return }

            let handleOpen = { [weak self] in
                guard let self, !self.isOpen else { return }
                self.isOpen = true
                self.onOpen()
            }
            let handleClose = { [weak self] in
                guard let self, self.isOpen else { return }
                self.isOpen = false
                self.onClose()
            }

            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main,
                    using: { _ in handleOpen() }
                ),
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main,
                    using: { _ in handleClose() }
                ),
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main,
                    using: { _ in handleClose() }
                ),
            ]

            if window.isVisible {
                DispatchQueue.main.async(execute: handleOpen)
            }
        }

        private func removeObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if isOpen {
                isOpen = false
                onClose()
            }
        }

        deinit {
            removeObservers()
        }
    }
}

struct PocketPicMenuBarPanel: View {
    @EnvironmentObject private var photoStore: PhotoStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var cameraSessionID = UUID()
    @State private var isCameraActive = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isCameraActive {
                    CameraView(onDismiss: closePanel)
                        .id(cameraSessionID)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Starting camera…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 480, height: 400)

            Divider()

            HStack {
                Button("Open PocketPic…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: PocketPicWindowID.mainApp)
                    closePanel()
                }
                .buttonStyle(.link)

                Spacer(minLength: 0)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            ZStack {
                ActiveSpaceMenuBarWindowConfigurator()
                MenuBarPanelLifecycleObserver(
                    onOpen: openCameraSession,
                    onClose: closeCameraSession
                )
            }
        }
    }

    private func openCameraSession() {
        cameraSessionID = UUID()
        photoStore.refreshPhotos()
        isCameraActive = true
    }

    private func closeCameraSession() {
        isCameraActive = false
    }

    private func closePanel() {
        closeCameraSession()
        dismiss()
    }
}
#endif
