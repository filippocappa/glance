// CaptureEngine.swift
// Glance
//
// Core capture engine wrapping ScreenCaptureKit.
// Configures SCStream with a sourceRect so the WindowServer's compositor
// crops at the GPU level, sending only the selected bounding-box pixels
// over the XPC/IPC boundary. This keeps CPU and GPU overhead near zero
// compared to capturing the full display and cropping in user-space.

import ScreenCaptureKit
import CoreMedia
import Combine
import AppKit
import IOSurface

// MARK: - CaptureEngine

/// The capture engine manages an ``SCStream`` session that streams a
/// sub-region of a display into an ``IOSurface`` for zero-copy rendering
/// inside a PiP overlay.
///
/// ## Architecture
///
/// ```
/// ┌────────────────────┐
/// │   WindowServer     │  ← crops sourceRect on the GPU
/// │  (compositor)      │
/// └────────┬───────────┘
///          │ IOSurface (XPC)
///          ▼
/// ┌────────────────────┐
/// │   CaptureEngine    │  ← receives CMSampleBuffer, extracts IOSurface
/// │  (SCStreamOutput)  │
/// └────────┬───────────┘
///          │ MainActor
///          ▼
/// ┌────────────────────┐
/// │     AppState       │  ← currentFrame drives SwiftUI / CALayerHost
/// └────────────────────┘
/// ```
///
/// ## Key Design Decisions
///
/// 1. **sourceRect on SCStreamConfiguration**: This is the single most
///    important optimisation. By setting `config.sourceRect` the
///    WindowServer only composites and transfers the selected rectangle,
///    not the entire display. The output resolution is set to match the
///    sourceRect (in backing pixels) so no scaling is performed either.
///
/// 2. **IOSurface zero-copy path**: We extract the `IOSurface` directly
///    from the `CVPixelBuffer` attached to each `CMSampleBuffer`.
///    The surface is already in GPU-accessible memory so the PiP overlay
///    can render it without any CPU-side copy or format conversion.
///
/// 3. **Workspace monitoring**: We observe `NSWorkspace` notifications
///    to detect when the source application is hidden or minimised.
///    When that happens we mark the stream as paused so the UI can show
///    an appropriate placeholder instead of a stale frame.
///
/// 4. **@Observable (not ObservableObject)**: Uses the Swift 5.9
///    Observation framework so SwiftUI views automatically track only
///    the properties they actually read, reducing unnecessary redraws.
@Observable
final class CaptureEngine: NSObject {

    // MARK: Observed properties

    /// Whether the SCStream is currently running.
    var isRunning: Bool = false

    // MARK: Private state

    /// The active ScreenCaptureKit stream, if any.
    private var stream: SCStream?

    /// The configuration object used for the current (or last) stream.
    /// Retained so that ``updateSourceRect(_:)`` can mutate and re-apply it.
    private var streamConfiguration: SCStreamConfiguration?

    /// Weak back-reference to the shared application state.
    /// We write captured frames and status flags here.
    private weak var appState: AppState?

    /// Tokens for NSWorkspace notification observers.
    /// Removed on ``stopCapture()`` or ``deinit``.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Dedicated serial queue for receiving SCStream output.
    /// `.userInteractive` QoS ensures frames are processed promptly.
    private let captureQueue = DispatchQueue(
        label: "com.glance.capture",
        qos: .userInteractive
    )

    // MARK: Callbacks & Rendering Pipeline

    /// Callback invoked on the main thread when a new frame is decoded and ready for display.
    var onFrameReceived: ((CVPixelBuffer) -> Void)?

    /// Lock protecting the rendering state for frame-dropping behavior.
    private let renderingLock = NSLock()

    /// Tracks whether a frame is currently being processed/rendered on the main thread.
    private var isProcessingFrame = false

    // MARK: Lifecycle

    deinit {
        // Belt-and-suspenders cleanup of notification observers.
        // (stopCapture should already have removed them, but the engine
        //  might be deallocated without an explicit stop.)
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - Public API

    /// Start capturing the specified rectangle of *display*.
    ///
    /// - Parameters:
    ///   - display: The ``SCDisplay`` to capture from.
    ///   - sourceRect: The sub-region of the display to capture, in
    ///     **display-native (un-scaled) points**. The WindowServer will
    ///     crop to this rectangle at the compositor level.
    ///   - appState: The shared ``AppState`` that receives frames and
    ///     status updates.
    ///
    /// - Throws: Any error from ScreenCaptureKit stream setup.
    func startCapture(
        display: SCDisplay,
        sourceRect: CGRect,
        appState: AppState
    ) async throws {
        // Ensure any previous session is torn down first.
        if isRunning {
            await stopCapture()
        }

        self.appState = appState

        // -----------------------------------------------------------------
        // Build SCStreamConfiguration
        // -----------------------------------------------------------------
        let config = SCStreamConfiguration()

        // ★ sourceRect — the KEY efficiency lever ★
        // Tells the WindowServer to only composite this sub-region.
        // The compositor performs the crop on the GPU *before* transferring
        // pixel data over the IPC surface, so we never pay for a full-
        // screen capture.
        config.sourceRect = sourceRect

        // Match output dimensions to the backing-pixel size of the
        // sourceRect. NSScreen.backingScaleFactor is typically 2 on Retina.
        // By matching exactly we avoid any up-/down-scaling.
        let scale = Self.scaleFactor(for: display)
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)

        // 60 fps — smooth and fluid without choking the CPU/GPU.
        // SCStream will skip frames if rendering can't keep up.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        // Hide the system cursor inside the captured region.
        // The user's own cursor is visible on-screen; duplicating it
        // in the PiP window would be distracting.
        config.showsCursor = false

        // BGRA is the native format of IOSurface on macOS.
        // Using it avoids any pixel-format conversion in the pipeline.
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Allow up to 3 frames in the pipeline (capture → process → render).
        // This provides a small buffer to absorb scheduling jitter without
        // introducing visible latency.
        config.queueDepth = 3

        self.streamConfiguration = config

        // -----------------------------------------------------------------
        // Build SCContentFilter
        // -----------------------------------------------------------------
        // We capture the entire display (no window exclusions).
        // The sourceRect in the configuration limits what is actually sent.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // -----------------------------------------------------------------
        // Create and start the stream
        // -----------------------------------------------------------------
        let newStream = SCStream(
            filter: filter,
            configuration: config,
            delegate: self          // SCStreamDelegate for error handling
        )

        // Register ourselves as the output handler on a dedicated serial
        // queue. ScreenCaptureKit calls us back here with each new frame.
        try newStream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: captureQueue
        )

        // Actually start the capture. This is the async call that requests
        // the WindowServer to begin compositing frames for us.
        try await newStream.startCapture()

        self.stream = newStream
        self.isRunning = true

        // Update UI state on the main actor.
        await MainActor.run {
            appState.isStreaming = true
        }

        // Begin monitoring the source app for hide/unhide so we can
        // pause the stream indicator in the UI.
        setupWorkspaceMonitoring()
    }

    /// Stop the current capture session and clean up all resources.
    ///
    /// Safe to call even if no stream is running.
    func stopCapture() async {
        // Remove workspace observers first so they don't fire during
        // teardown.
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        // Tear down the SCStream.
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("[CaptureEngine] Error stopping capture: \(error.localizedDescription)")
            }
        }

        self.stream = nil
        self.streamConfiguration = nil
        self.isRunning = false

        // Reset UI state on the main actor.
        await MainActor.run {
            appState?.isStreaming = false
            appState?.isPaused = false
        }
    }

    /// Update the captured sub-region on a **live** stream.
    ///
    /// Call this when the source window moves or resizes so the PiP
    /// continues to track the correct area. The update is applied
    /// atomically by ScreenCaptureKit; there is no visible glitch.
    ///
    /// - Parameter rect: The new source rectangle in display points.
    /// - Throws: If the configuration update fails.
    func updateSourceRect(_ rect: CGRect) async throws {
        guard let stream = stream,
              let config = streamConfiguration else {
            return
        }

        // Mutate the existing configuration and re-apply it.
        // ScreenCaptureKit handles the transition seamlessly.
        config.sourceRect = rect

        // Recalculate output dimensions so they continue to match
        // the sourceRect exactly (no scaling).
        if appState != nil,
           let display = try await ScreenPicker.display(for: rect) {
            let scale = Self.scaleFactor(for: display)
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
        }

        try await stream.updateConfiguration(config)
    }
    // MARK: - Scale Factor Utility

    /// SCDisplay does not expose a `scaleFactor` property directly.
    /// We find the matching NSScreen and use its `backingScaleFactor`.
    /// Falls back to 2.0 (Retina) if no match is found.
    private static func scaleFactor(for display: SCDisplay) -> CGFloat {
        let displayFrame = CGRect(
            x: CGFloat(display.frame.origin.x),
            y: CGFloat(display.frame.origin.y),
            width: CGFloat(display.frame.width),
            height: CGFloat(display.frame.height)
        )
        for screen in NSScreen.screens {
            if screen.frame.origin == displayFrame.origin
                && screen.frame.size == displayFrame.size {
                return screen.backingScaleFactor
            }
        }
        return 2.0  // Default to Retina
    }

    // MARK: - Workspace Monitoring


    /// Observe workspace notifications to detect when the source app is
    /// hidden or minimised. This lets the UI show a "paused" state
    /// instead of rendering stale or black frames.
    private func setupWorkspaceMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter

        // --- App hidden ---------------------------------------------------
        let hideObserver = nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier == self.appState?.sourceAppPID
            else { return }

            self.appState?.isPaused = true
        }
        workspaceObservers.append(hideObserver)

        // --- App unhidden -------------------------------------------------
        let unhideObserver = nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier == self.appState?.sourceAppPID
            else { return }

            self.appState?.isPaused = false
        }
        workspaceObservers.append(unhideObserver)

        // --- App terminated -----------------------------------------------
        // If the source app quits entirely, stop the capture session.
        let terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier == self.appState?.sourceAppPID
            else { return }

            // The source app is gone — tear down asynchronously.
            Task { [weak self] in
                await self?.stopCapture()
            }
        }
        workspaceObservers.append(terminateObserver)
    }
}

extension CaptureEngine: SCStreamOutput {

    /// Called by ScreenCaptureKit on `captureQueue` each time a new frame
    /// is ready.
    ///
    /// We implement a frame-dropping pipeline to ensure zero latency and
    /// prevent scheduling lag. If a new frame arrives while the previous
    /// frame is still rendering on the GPU, we drop the new frame.
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // We only care about screen content, not audio.
        guard type == .screen else { return }

        // Check the sample buffer status — ScreenCaptureKit can send
        // status-only buffers (e.g. idle/blank notifications).
        guard sampleBuffer.isValid else { return }

        // Retrieve the backing CVPixelBuffer.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Drop frame if the main thread/GPU is still processing the previous one.
        renderingLock.lock()
        if isProcessingFrame {
            renderingLock.unlock()
            return // Drop frame
        }
        isProcessingFrame = true
        renderingLock.unlock()

        // Extract the IOSurface — this is a zero-copy handle to the same
        // GPU memory that the WindowServer wrote into.
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else {
            renderingLock.lock()
            isProcessingFrame = false
            renderingLock.unlock()
            return
        }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)

        // Dispatch frame directly to the main thread for rendering.
        // We do NOT modify any @Observable properties here to avoid triggering
        // expensive SwiftUI view body re-evaluations.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            defer {
                self.renderingLock.lock()
                self.isProcessingFrame = false
                self.renderingLock.unlock()
            }
            
            // Keep AppState currentFrame updated for completeness
            self.appState?.currentFrame = surface
            
            // Render directly onto the CAMetalLayer bypassing SwiftUI
            self.onFrameReceived?(pixelBuffer)
        }
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {

    /// Called when the stream terminates unexpectedly (e.g. the display
    /// is disconnected, or ScreenCaptureKit encounters an internal error).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[CaptureEngine] Stream stopped with error: \(error.localizedDescription)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false
            self.appState?.isStreaming = false
            self.appState?.isPaused = true
            self.appState?.errorMessage = error.localizedDescription
        }

        // Clean up workspace observers since the stream is dead.
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }
}
