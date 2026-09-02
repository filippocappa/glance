// GlanceApp.swift
// Glance — Universal Picture-in-Picture for macOS
//
// Menu bar agent app (LSUIElement = YES). MenuBarExtra provides the status
// item; GlanceCoordinator owns every piece of long-lived state.
//
// The coordinator exists because global hotkeys must be registered exactly
// once, for the lifetime of the process. Registering them from a SwiftUI
// `App`'s initializer is not possible (its `@State` is not yet available), and
// registering from menu content would re-register every time the menu opens.

import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin

// MARK: - GlanceCoordinator

/// Owns the app's state, capture engine, and windows.
@MainActor
@Observable
final class GlanceCoordinator {

    let appState = AppState()
    let captureEngine = CaptureEngine()

    private let selectionCoordinator = SelectionCoordinator()
    private let splashController = SplashWindowController()

    /// The active PiP window controller, or `nil` when nothing is being shown.
    private(set) var windowController: GlanceWindowController?

    /// Last known Screen Recording status, for the menu.
    var hasPermission: Bool = Permissions.hasScreenRecordingAccess()

    init() {
        Log.installCrashDiagnostics()
        registerGlobalShortcuts()

        // The stream can end without us: "Stop Sharing" in the system recording
        // pill, a failure, or the source disappearing. Close the PiP and return
        // to idle in every case, preserving any error message across the reset
        // so the menu can still explain what happened.
        captureEngine.onStreamEnded = { [weak self] in
            guard let self, self.windowController != nil else { return }
            let message = self.appState.errorMessage
            Log.window.info("Stream ended externally — closing PiP")
            self.stopGlance()
            self.appState.errorMessage = message
        }

        // First-run onboarding. This has to be deferred by one run-loop turn:
        // `@State` initialisers run while the App value is being built, before
        // NSApplication has finished launching, and ordering a window in at
        // that point does nothing.
        //
        // An NSApplicationDelegateAdaptor was tried first and does not work
        // here — the only place to wire the delegate up is the MenuBarExtra's
        // content `.onAppear`, which does not run until the user actually opens
        // the menu, by which time applicationDidFinishLaunching is long gone.
        DispatchQueue.main.async { [weak self] in
            self?.splashController.showIfFirstRun()
        }
    }

    // MARK: Global shortcuts

    private func registerGlobalShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .newCapture) { [weak self] in
            self?.startNewGlance()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleGhostMode) { [weak self] in
            self?.toggleGhostMode()
        }
        Log.window.info("Global shortcuts registered")
    }

    // MARK: Capture lifecycle

    /// Check permission → select a region → start capture → show the PiP.
    func startNewGlance() {
        guard Permissions.ensureScreenRecordingAccess() else {
            hasPermission = false
            appState.errorMessage = "Screen Recording permission required. Grant it, then relaunch Glance."
            showSettings()
            return
        }
        hasPermission = true

        // Single-instance: tear down any existing PiP before selecting again.
        stopGlance()

        appState.errorMessage = nil
        appState.isSelecting = true
        Log.selection.info("Entering selection mode")

        selectionCoordinator.beginSelection { [weak self] selection in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appState.isSelecting = false

                guard let selection else {
                    Log.selection.info("Selection cancelled")
                    return
                }
                Log.selection.info("""
                    Selected \(NSStringFromRect(selection.rect), privacy: .public) (cocoa) \
                    on screen \(NSStringFromRect(selection.screen.frame), privacy: .public)
                    """)

                Task { await self.startCapture(selection: selection) }
            }
        }
    }

    private func startCapture(selection: Selection) async {
        do {
            appState.sourceRect = selection.rect

            // CaptureEngine picks window-relative or display capture itself and
            // reports the crop it settled on via `appState.captureSize`.
            try await captureEngine.startCapture(selection: selection, appState: appState)

            // Size the PiP from the ACTUAL crop, not the raw selection: in
            // window mode the crop is clamped to the window's content rect, so
            // using the selection would give the panel the wrong aspect ratio.
            let capture = appState.captureSize
            guard capture.width > 0, capture.height > 0 else {
                appState.errorMessage = "Capture produced an empty region"
                await captureEngine.stopCapture()
                return
            }

            let pipSize = GlanceWindowController.initialPanelSize(for: capture)
            let screen = selection.screen
            let position = CGPoint(
                x: screen.visibleFrame.maxX - pipSize.width - SnapEngine.margin,
                y: screen.visibleFrame.minY + SnapEngine.margin
            )

            appState.windowSize = pipSize
            appState.windowPosition = position

            let controller = GlanceWindowController(
                appState: appState,
                captureEngine: captureEngine
            )
            controller.show(size: pipSize, position: position)
            windowController = controller

        } catch {
            let message = Permissions.describe(error)
            Log.capture.error("Failed to start capture — \(message, privacy: .public)")
            appState.errorMessage = message
            await captureEngine.stopCapture()
        }
    }

    /// Stop the current session and release everything it held.
    func stopGlance() {
        windowController?.close()
        windowController = nil
    }

    /// Flip Ghost Mode on the active PiP. No-op when nothing is showing.
    func toggleGhostMode() {
        guard let windowController else {
            Log.window.debug("Ghost Mode hotkey ignored — no active PiP")
            return
        }
        windowController.toggleGhostMode()
    }

    // MARK: Settings

    func showSettings() {
        splashController.show()
    }

    func refreshPermission() {
        hasPermission = Permissions.hasScreenRecordingAccess()
    }
}

// MARK: - App Entry Point

@main
struct GlanceApp: App {
    @State private var coordinator = GlanceCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
                .onAppear { coordinator.refreshPermission() }
        } label: {
            // Template rendering lets AppKit tint the glyph for the current
            // menu-bar appearance. While a capture is live the icon switches to
            // `.original` so it can carry the accent colour and signal at a
            // glance that Glance is recording.
            if coordinator.appState.isStreaming {
                Image(systemName: "pip.fill")
                    .renderingMode(.original)
                    .foregroundStyle(Theme.accent)
            } else {
                Image(systemName: "pip")
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu Bar View

/// The status-item dropdown. Deliberately shallow: two actions, a Settings
/// submenu, and Quit.
struct MenuBarView: View {
    @Bindable var coordinator: GlanceCoordinator

    var body: some View {
        Group {
            Button(menuTitle("New Capture", .newCapture)) {
                coordinator.startNewGlance()
            }

            Button(ghostTitle) {
                coordinator.toggleGhostMode()
            }
            .disabled(coordinator.windowController == nil)

            if coordinator.appState.isStreaming {
                Button("Stop Capture") { coordinator.stopGlance() }
            }

            Divider()

            Menu("Settings") {
                // Mirrors Hum's settings block: version, repository, login item,
                // and a way back into onboarding.
                Text("Glance \(Bundle.main.shortVersion)")

                Button("GitHub Repository") {
                    if let url = URL(string: "https://github.com/filippocappa/glance") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button(LaunchAtLogin.isEnabled ? "✓ Open at Login" : "Open at Login") {
                    LaunchAtLogin.isEnabled.toggle()
                }

                // KeyboardShortcuts.Recorder captures live key events and so
                // needs a real window; shortcut editing lives in the splash.
                Button("Shortcuts & Onboarding…") { coordinator.showSettings() }

                Divider()

                if coordinator.hasPermission {
                    Text("Screen Recording: Allowed")
                } else {
                    Button("Grant Screen Recording…") {
                        Permissions.openScreenRecordingSettings()
                    }
                }
            }

            if let error = coordinator.appState.errorMessage {
                Divider()
                Text(error)
            }

            Divider()

            Button("Quit Glance") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var ghostTitle: String {
        let base = coordinator.appState.isGhostMode ? "Exit Ghost Mode" : "Toggle Ghost Mode"
        return menuTitle(base, .toggleGhostMode)
    }

    /// Appends the current hotkey to a menu title.
    ///
    /// NSMenu key equivalents cannot represent an arbitrary KeyboardShortcuts
    /// binding, so the combination is shown as text instead.
    private func menuTitle(_ base: String, _ name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return base }
        return "\(base)  \(shortcut)"
    }
}
