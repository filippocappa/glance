// GlanceApp.swift
// Glance — Universal Picture-in-Picture for macOS
//
// The main entry point for the Glance app.
// This is a menu bar agent app (LSUIElement = YES) that does not appear in the Dock.
// It uses SwiftUI's MenuBarExtra for the status item and orchestrates
// the selection → capture → PiP window pipeline.

import SwiftUI
import ScreenCaptureKit

// MARK: - App Entry Point

@main
struct GlanceApp: App {
    // Global state — analogous to a React Context provider wrapping the entire app.
    // This single @State instance is the source of truth for all components.
    @State private var appState = AppState()
    
    // The capture engine manages SCStream sessions
    @State private var captureEngine = CaptureEngine()
    
    // Selection coordinator manages the overlay window lifecycle
    @State private var selectionCoordinator = SelectionCoordinator()
    
    // The PiP window controller (created when capture starts)
    @State private var windowController: GlanceWindowController?
    
    // Permission state
    @State private var hasPermission: Bool? = nil
    
    var body: some Scene {
        // MenuBarExtra is the SwiftUI way to create a menu bar status item.
        // This replaces the need for manual NSStatusItem setup.
        MenuBarExtra {
            MenuBarView(
                appState: appState,
                hasPermission: hasPermission,
                onNewGlance: { startNewGlance() },
                onStopGlance: { stopGlance() },
                onCheckPermission: { await checkPermission() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            // The menu bar icon — an SF Symbol representing PiP
            Label("Glance", systemImage: "pip")
                .labelStyle(.iconOnly)
        }
        .menuBarExtraStyle(.menu)
    }
    
    // MARK: - Actions
    
    /// Start a new Glance session: check permissions → select region → start capture → show PiP
    private func startNewGlance() {
        Task { @MainActor in
            // 1. Check permission
            let permitted = await Permissions.checkScreenRecordingPermission()
            hasPermission = permitted
            
            guard permitted else {
                Permissions.openScreenRecordingSettings()
                return
            }
            
            // 2. Enter selection mode
            appState.isSelecting = true
            
            selectionCoordinator.beginSelection { selectedRect in
                appState.isSelecting = false
                
                guard let rect = selectedRect else {
                    // User cancelled
                    return
                }
                
                // 3. Start capture
                Task {
                    await startCapture(sourceRect: rect)
                }
            }
        }
    }
    
    /// Start the ScreenCaptureKit stream and show the PiP window.
    private func startCapture(sourceRect: CGRect) async {
        do {
            // Find the display containing the selected rect
            guard let display = try await ScreenPicker.display(for: sourceRect) else {
                appState.errorMessage = "Could not find display for selected region"
                return
            }
            
            appState.sourceRect = sourceRect
            appState.targetDisplay = display
            
            // Try to identify the source app (for bring-to-front feature)
            let midPoint = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
            if let app = try? await ScreenPicker.application(at: midPoint) {
                appState.sourceAppPID = app.processIdentifier
            }
            
            // Start the capture engine
            try await captureEngine.startCapture(
                display: display,
                sourceRect: sourceRect,
                appState: appState
            )
            
            // Calculate PiP window size (fit within 400px width, maintain aspect ratio)
            let maxWidth: CGFloat = 400
            let aspectRatio = sourceRect.width / sourceRect.height
            let pipWidth = min(maxWidth, sourceRect.width)
            let pipHeight = pipWidth / aspectRatio
            let pipSize = CGSize(width: pipWidth, height: pipHeight)
            
            // Position in bottom-right corner initially
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let initialPosition = CGPoint(
                x: screen.visibleFrame.maxX - pipSize.width - SnapEngine.margin,
                y: screen.visibleFrame.minY + SnapEngine.margin
            )
            
            appState.windowSize = pipSize
            appState.windowPosition = initialPosition
            
            // Create and show the PiP window
            let controller = GlanceWindowController(
                appState: appState,
                captureEngine: captureEngine
            )
            controller.show(size: pipSize, position: initialPosition)
            windowController = controller
            
        } catch {
            appState.errorMessage = "Failed to start capture: \(error.localizedDescription)"
        }
    }
    
    /// Stop the current Glance session.
    private func stopGlance() {
        windowController?.close()
        windowController = nil
    }
    
    /// Check screen recording permission.
    private func checkPermission() async {
        hasPermission = await Permissions.checkScreenRecordingPermission()
    }
}

// MARK: - Menu Bar View

/// The dropdown menu content for the menu bar status item.
/// Analogous to a dropdown component in React.
struct MenuBarView: View {
    let appState: AppState
    let hasPermission: Bool?
    let onNewGlance: () -> Void
    let onStopGlance: () -> Void
    let onCheckPermission: () async -> Void
    let onQuit: () -> Void
    
    var body: some View {
        Group {
            if appState.isStreaming {
                // Active session controls
                Button("Stop Glance") {
                    onStopGlance()
                }
                .keyboardShortcut("w", modifiers: .command)
                
                Divider()
                
                Button("New Glance") {
                    onStopGlance()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onNewGlance()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            } else {
                // No active session
                Button("New Glance") {
                    onNewGlance()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            Divider()
            
            // Permission status
            if let permitted = hasPermission {
                if permitted {
                    Label("Screen Recording: Allowed", systemImage: "checkmark.circle.fill")
                        .disabled(true)
                } else {
                    Button("Grant Screen Recording Permission…") {
                        Permissions.openScreenRecordingSettings()
                    }
                }
            } else {
                Button("Check Permission") {
                    Task { await onCheckPermission() }
                }
            }
            
            Divider()
            
            // Error display
            if let error = appState.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Divider()
            }
            
            Button("Quit Glance") {
                onQuit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
