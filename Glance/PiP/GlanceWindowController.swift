import AppKit
import SwiftUI
import Combine

// MARK: - GlanceWindowController
// ─────────────────────────────────────────────────────────────────────────────
// The main controller for Glance's floating PiP window.
// It orchestrates a single-window architecture that supports:
// - Borderless, floating window level configuration.
// - Mouse event click-through when the hover controls are hidden.
// - SwiftUI DragGesture handling on the window's content view for moving/dragging.
// - Native spring snapping animation on release (.spring(response: 0.3, dampingFraction: 0.6)).
// - Dynamic resize based on zoom presets.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GlanceWindowController {
    
    // MARK: - Properties
    
    /// The single floating panel displaying video and controls.
    private var panel: NSPanel?
    
    /// Shared application state.
    private let appState: AppState
    
    /// The capture engine.
    private let captureEngine: CaptureEngine
    
    /// Timer checking if the mouse is hovering over the window.
    private var hoverTimer: Timer?
    
    // MARK: - Initialization
    
    init(appState: AppState, captureEngine: CaptureEngine) {
        self.appState = appState
        self.captureEngine = captureEngine
    }
    
    // MARK: - Show / Close
    
    /// Show the PiP window with the given initial size and position.
    ///
    /// - Parameters:
    ///   - size: Initial size of the PiP window.
    ///   - position: Initial screen position.
    func show(size: CGSize, position: CGPoint) {
        // Create the single borderless floating panel
        let panel = NSPanel(
            contentRect: NSRect(origin: position, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false // We handle movement via DragGesture
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Starts in click-through mode
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .utilityWindow
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        
        // SwiftUI Content View
        let contentView = PiPContentView(
            appState: appState,
            captureEngine: captureEngine,
            window: panel,
            onClose: { [weak self] in
                self?.close()
            },
            onBringToFront: { [weak self] in
                self?.bringSourceToFront()
            },
            onZoomLevelChanged: { [weak self] newZoom in
                self?.resizeWindow(toZoom: newZoom)
            }
        )
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        
        self.panel = panel
        
        // Make the panel visible
        panel.makeKeyAndOrderFront(nil)
        
        // Start mouse hover tracking
        startHoverTracking()
        
        // Snap to nearest corner initially using spring animation
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let targetOrigin = SnapEngine.snapPosition(for: panel.frame, on: screen)
        panel.setFrameOrigin(targetOrigin)
    }
    
    /// Close the PiP window and stop capture.
    func close() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        
        // Clear capture engine frame callback
        captureEngine.onFrameReceived = nil
        
        Task {
            await captureEngine.stopCapture()
        }
        
        panel?.orderOut(nil)
        panel = nil
        
        appState.reset()
    }
    
    // MARK: - Hover Tracking Timer
    
    /// Periodically queries the global mouse location to detect if the cursor
    /// is hovering over the PiP window.
    /// - When hovering: disables click-through (ignoresMouseEvents = false)
    ///   so controls can intercept clicks and dragging works.
    /// - Otherwise: enables click-through (ignoresMouseEvents = true) so
    ///   clicks pass directly to the desktop below.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            Task { @MainActor in
                guard let panel = self.panel else { return }
                
                // If currently dragging, do not toggle mouse events or hide controls
                guard !self.appState.isDragging else { return }
                
                let mouseLocation = NSEvent.mouseLocation
                let windowFrame = panel.frame
                let isInside = windowFrame.contains(mouseLocation)
                
                if isInside != self.appState.isHovering {
                    // Update ignoresMouseEvents depending on hover state.
                    panel.ignoresMouseEvents = !isInside
                    
                    // Animate the SwiftUI state change
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.appState.isHovering = isInside
                    }
                }
            }
        }
    }
    
    // MARK: - Resizing
    
    private func resizeWindow(toZoom zoom: CGFloat) {
        guard let panel = panel else { return }
        
        let sourceRect = appState.sourceRect
        let aspectRatio = sourceRect.width / sourceRect.height
        
        let baseWidth = min(400, sourceRect.width)
        let baseHeight = baseWidth / aspectRatio
        
        let newSize = CGSize(width: baseWidth * zoom, height: baseHeight * zoom)
        let currentFrame = panel.frame
        
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.minY,
            width: newSize.width,
            height: newSize.height
        )
        
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let targetOrigin = SnapEngine.snapPosition(for: targetFrame, on: screen)
        
        // Resize frame size instantly, then spring-snap the origin to the correct corner
        panel.setFrame(NSRect(origin: currentFrame.origin, size: newSize), display: true)
        SnapEngine.animateSpring(window: panel, to: targetOrigin)
    }
    
    // MARK: - Source App Interaction
    
    private func bringSourceToFront() {
        guard let pid = appState.sourceAppPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}

// MARK: - PiPContentView
// ─────────────────────────────────────────────────────────────────────────────
// The root SwiftUI view for the single-window PiP view hierarchy.
// Orchestrates the Metal renderer, paused state, and hover controls.
// Handles user drag events to move and snap the PiP window.
// ─────────────────────────────────────────────────────────────────────────────

struct PiPContentView: View {
    let appState: AppState
    let captureEngine: CaptureEngine
    let window: NSWindow
    
    var onClose: () -> Void
    var onBringToFront: () -> Void
    var onZoomLevelChanged: (CGFloat) -> Void
    
    @State private var initialWindowOrigin: CGPoint? = nil
    
    var body: some View {
        ZStack {
            // High-performance GPU video stream rendering
            PiPVideoView(captureEngine: captureEngine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Paused overlay view
            if appState.isPaused {
                PausedOverlayView()
            }
            
            // UI Controls overlay
            HoverControlsView(
                isHovering: appState.isHovering,
                onClose: onClose,
                onBringToFront: onBringToFront,
                zoomLevel: Binding(
                    get: { appState.zoomLevel },
                    set: { appState.zoomLevel = $0 }
                )
            )
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if initialWindowOrigin == nil {
                        initialWindowOrigin = window.frame.origin
                        // Set dragging flag to prevent timer from toggling ignoresMouseEvents
                        appState.isDragging = true
                    }
                    
                    if let startOrigin = initialWindowOrigin {
                        let translation = value.translation
                        // Map top-down SwiftUI Y coordinates to bottom-up AppKit coordinates
                        let newOrigin = CGPoint(
                            x: startOrigin.x + translation.width,
                            y: startOrigin.y - translation.height
                        )
                        window.setFrameOrigin(newOrigin)
                    }
                }
                .onEnded { _ in
                    initialWindowOrigin = nil
                    appState.isDragging = false
                    
                    // Snap window to the nearest edge using native spring physics (.spring(0.3, 0.6))
                    let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
                    let targetOrigin = SnapEngine.snapPosition(for: window.frame, on: screen)
                    SnapEngine.animateSpring(window: window, to: targetOrigin)
                }
        )
        .onChange(of: appState.zoomLevel) { _, newValue in
            onZoomLevelChanged(newValue)
        }
    }
}
