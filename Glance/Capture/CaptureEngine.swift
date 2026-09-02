// CaptureEngine.swift
// Glance
//
// Core capture engine wrapping ScreenCaptureKit.
//
// The stream targets a single window via SCContentFilter(desktopIndependentWindow:)
// and optionally narrows to a sub-region with SCStreamConfiguration.sourceRect,
// so the WindowServer's compositor crops on the GPU and only the selected pixels
// cross the XPC boundary.

import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit
import IOSurface

// MARK: - CaptureEngine

/// Manages an ``SCStream`` session that streams a window (or a sub-region of
/// one) into an ``IOSurface`` for zero-copy presentation in the PiP overlay.
///
/// ## Pipeline
///
/// ```
/// WindowServer ──IOSurface(XPC)──▶ CaptureEngine ──main queue──▶ VideoLayerView
///  (GPU crop)                      (SCStreamOutput)              (layer.contents)
/// ```
///
/// ## Ordering invariants
///
/// 1. Screen Recording access is preflighted **before** any `SCStream` is
///    constructed. Creating a stream while TCC denies access yields
///    `SCStreamErrorDomain` -3801 and a half-initialised stream object.
/// 2. `self.stream` is assigned before `startCapture()` is awaited, so the
///    stream cannot be deallocated mid-start (a released `SCStream` stops
///    delivering frames without reporting an error).
@Observable
final class CaptureEngine: NSObject {

    // MARK: Observed properties

    /// Whether the SCStream is currently running.
    var isRunning: Bool = false

    // MARK: Private state

    /// The active ScreenCaptureKit stream, if any.
    ///
    /// This strong reference is load-bearing: `SCStream` stops delivering
    /// frames the moment its last reference goes away, and it does so silently
    /// — `stream(_:didStopWithError:)` is never called.
    private var stream: SCStream?

    /// The configuration object used for the current (or last) stream.
    /// Retained so that ``updateSourceRect(_:)`` can mutate and re-apply it.
    private var streamConfiguration: SCStreamConfiguration?

    /// What the current stream is filtered to.
    private var captureTarget: CaptureTarget?

    /// The display being captured in display mode, retained so the content
    /// filter can be rebuilt (see ``refreshExcludedWindows()``). `nil` in window
    /// mode, where nothing needs excluding.
    private var captureDisplay: SCDisplay?

    /// The `NSScreen` matching ``captureDisplay``, used for the Cocoa →
    /// ScreenCaptureKit coordinate flip.
    private var captureScreen: NSScreen?

    /// The selected region in Cocoa global coordinates.
    private var selectionRect: CGRect = .zero

    /// How many Glance windows the current filter excludes, so a refresh that
    /// would change nothing can be skipped.
    private var excludedWindowCount: Int = -1

    /// Point-to-pixel scale reported by the content filter.
    private var pointPixelScale: CGFloat = 2.0

    /// Weak back-reference to the shared application state.
    private weak var appState: AppState?

    /// Tokens for NSWorkspace notification observers.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Dedicated serial queue for receiving SCStream output.
    private let captureQueue = DispatchQueue(
        label: "com.glance.capture",
        qos: .userInteractive
    )

    // MARK: Frame delivery

    /// Invoked on the main thread when the stream ends on its own — whether
    /// because the user pressed "Stop Sharing" in the menu bar pill, or because
    /// the stream failed. The owner should tear the PiP down either way; a dead
    /// stream cannot be revived.
    var onStreamEnded: (() -> Void)?

    /// Invoked on the main thread with each new frame's IOSurface.
    ///
    /// Prefer ``attachRenderer(_:)`` over assigning this directly — it replays
    /// the buffered frame so a late renderer is not left with a black panel.
    var onFrameReceived: ((IOSurface) -> Void)?

    /// Installs the frame callback and immediately replays the most recent
    /// frame, if one has already arrived.
    @MainActor
    func attachRenderer(_ renderer: @escaping (IOSurface) -> Void) {
        onFrameReceived = renderer
        if let buffered = withRenderingLock({ lastSurface }) {
            Log.capture.info("Replaying buffered frame to newly attached renderer")
            renderer(buffered)
        }
    }

    /// Wall-clock time of the most recent delivered frame, guarded by
    /// ``renderingLock``. Used to distinguish "the source window is minimised"
    /// from "SCK briefly failed to list the window", which the old poll could
    /// not tell apart and which left the Paused overlay stuck over live video.
    private var lastFrameTime: CFAbsoluteTime = 0

    /// Total frames received from SCK (including dropped ones).
    private var receivedFrameCount: UInt64 = 0

    /// Lock protecting the frame-drop gate and the counters above.
    private let renderingLock = NSLock()

    /// Whether a frame is currently in flight to the main thread.
    private var isProcessingFrame = false

    /// The most recently received surface.
    ///
    /// The first frame reliably arrives ~70ms before SwiftUI builds the PiP
    /// view, so without this the opening frame was logged as
    /// "no renderer attached" and discarded, leaving the panel black until the
    /// source window next redrew. ``attachRenderer(_:)`` replays it.
    private var lastSurface: IOSurface?

    /// Runs `body` under ``renderingLock``.
    ///
    /// `NSLock.lock()`/`unlock()` are unavailable from async contexts (holding a
    /// lock across a suspension point can deadlock the cooperative pool), so
    /// every async caller goes through this synchronous, non-suspending helper.
    private func withRenderingLock<T>(_ body: () -> T) -> T {
        renderingLock.lock()
        defer { renderingLock.unlock() }
        return body()
    }

    // MARK: Lifecycle

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - Public API

    /// Start capturing the user's selected region.
    ///
    /// Prefers **window-relative** capture: if a single ordinary window sits
    /// under the selection, the stream is filtered to that window and the crop
    /// is expressed relative to the window's own content rect. ScreenCaptureKit
    /// then keeps the crop locked to that part of the window as it moves, so
    /// dragging Safari across the screen no longer leaves the PiP showing
    /// whatever is now behind it.
    ///
    /// Falls back to display capture when the selection is over the desktop or
    /// straddles several windows.
    func startCapture(selection: Selection, appState: AppState) async throws {
        guard Permissions.ensureScreenRecordingAccess() else {
            Log.capture.error("startCapture aborted — Screen Recording permission not granted")
            throw CaptureError.permissionDenied
        }

        // Single-instance: tear down any previous session first, so a second
        // "New Glance" cannot leave a zombie SCStream holding the recording
        // indicator open.
        await stopCapture()

        self.appState = appState
        self.captureScreen = selection.screen
        self.selectionRect = selection.rect

        guard selection.rect.width >= 2, selection.rect.height >= 2 else {
            throw CaptureError.invalidGeometry
        }

        // ── Resolve the capture target ───────────────────────────────────
        let target = try await resolveTarget(for: selection)
        self.captureTarget = target

        let filter: SCContentFilter
        let crop: CGRect

        switch target {
        case let .window(window, windowCrop):
            filter = SCContentFilter(desktopIndependentWindow: window)
            crop = windowCrop
            self.captureDisplay = nil
            Log.capture.info("""
                Window-relative capture — id=\(window.windowID, privacy: .public) \
                app=\(window.owningApplication?.applicationName ?? "?", privacy: .public) \
                windowFrame=\(NSStringFromRect(window.frame), privacy: .public) \
                crop=\(NSStringFromRect(windowCrop), privacy: .public)
                """)

        case let .display(display, displayCrop):
            // Excluding our own windows is mandatory in display mode: the PiP
            // panel floats above the captured region, so leaving it in the
            // filter feeds the panel's own output back in (infinite mirror).
            // A window filter cannot include our panel, so this is display-only.
            let excluded = (try? await ScreenPicker.glanceWindows()) ?? []
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            crop = displayCrop
            self.captureDisplay = display
            self.excludedWindowCount = excluded.count
            Log.capture.info("""
                Display capture (no single window under the selection) — \
                displayID=\(display.displayID, privacy: .public) \
                crop=\(NSStringFromRect(displayCrop), privacy: .public)
                """)
        }

        let scale = CGFloat(filter.pointPixelScale)
        self.pointPixelScale = scale

        guard crop.width >= 2, crop.height >= 2 else {
            Log.capture.error("Selection maps to an empty crop \(NSStringFromRect(crop), privacy: .public)")
            throw CaptureError.invalidGeometry
        }

        // ── Stream configuration ─────────────────────────────────────────
        let config = SCStreamConfiguration()

        // `sourceRect` is in POINTS, in the filter's content-rect space.
        config.sourceRect = crop

        // `destinationRect` is deliberately NOT set. It is measured in
        // output-surface PIXELS while `crop.size` is in points, so setting it to
        // the crop's point size on a 2x display confined the frame to a quarter
        // of the surface anchored at a corner. Unset, it defaults to the whole
        // surface.
        config.scalesToFit = false

        // Output resolution in BACKING PIXELS: crop points x display scale,
        // capped to what the PiP panel can actually show. SCK requires even
        // dimensions; an odd width silently produces a stream that never emits
        // a frame.
        let output = Self.outputSize(for: crop, scale: scale)
        config.width = output.width
        config.height = output.height
        if output.capped {
            Log.capture.info("""
                Output capped to \(output.width, privacy: .public)x\(output.height, privacy: .public) \
                from native \(Int(crop.width * scale), privacy: .public)x\(Int(crop.height * scale), privacy: .public) \
                — the panel cannot display more
                """)
        }

        guard config.width > 0, config.height > 0 else {
            Log.capture.error("Computed output size is empty (\(config.width)x\(config.height))")
            throw CaptureError.invalidGeometry
        }

        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // `colorSpaceName` is deliberately left at its default.
        //
        // Forcing sRGB made the compositor colour-convert every frame on a
        // wide-gamut display (every modern Mac panel is Display P3), for no
        // benefit: the IOSurface carries its own colour space and Core Animation
        // renders it correctly either way. The default is the display's own
        // space, which is a straight copy.
        config.showsCursor = false
        config.capturesAudio = false
        config.queueDepth = 3
        config.backgroundColor = .black

        self.streamConfiguration = config

        Log.capture.info("""
            SCStreamConfiguration: sourceRect=\(NSStringFromRect(crop), privacy: .public) \
            output=\(config.width, privacy: .public)x\(config.height, privacy: .public) \
            scale=\(scale, privacy: .public) pixelFormat=BGRA
            """)

        // ── Create and start ─────────────────────────────────────────────
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        // Retain BEFORE starting: if `startCapture()` suspends and the only
        // reference is this local, an intervening deallocation kills the stream
        // with no error reported.
        self.stream = newStream

        do {
            try await newStream.startCapture()
        } catch {
            Log.capture.error("SCStream.startCapture failed — \(Permissions.describe(error), privacy: .public)")
            self.stream = nil
            self.streamConfiguration = nil
            throw error
        }

        self.isRunning = true
        withRenderingLock {
            lastFrameTime = CFAbsoluteTimeGetCurrent()
            receivedFrameCount = 0
            isProcessingFrame = false
            lastSurface = nil
        }

        Log.capture.info("SCStream started successfully")

        await MainActor.run {
            appState.captureSize = crop.size
            appState.isStreaming = true
            appState.isPaused = false
            if case let .window(window, _) = target {
                appState.sourceAppPID = window.owningApplication?.processID
                appState.sourceWindowTitle = window.title
            }
        }

        setupWorkspaceMonitoring()
    }

    // MARK: - Target resolution

    /// What the stream is filtered to.
    enum CaptureTarget {
        /// A specific window, with the crop in the window filter's own
        /// content-rect space. Tracks the window as it moves.
        case window(SCWindow, crop: CGRect)
        /// A whole display, with the crop in display-relative top-left points.
        case display(SCDisplay, crop: CGRect)
    }

    /// Chooses between window-relative and display capture for a selection.
    private func resolveTarget(for selection: Selection) async throws -> CaptureTarget {
        // The selection overlay already decided, and showed the user its
        // decision as a highlight. Honour that exact window rather than
        // re-running the hit test here, where a window that moved in the
        // meantime could silently produce a different answer.
        if let candidate = selection.target,
           let window = try? await windowForID(candidate.windowID) {

            let cgRect = Self.cgGlobalRect(from: selection.rect)
            let windowFrame = window.frame
            let intersection = cgRect.intersection(windowFrame)

            if !intersection.isNull, intersection.width >= 2, intersection.height >= 2,
               windowFrame.width > 0, windowFrame.height > 0 {

                let filter = SCContentFilter(desktopIndependentWindow: window)
                let contentRect = filter.contentRect

                Log.capture.debug("""
                    Window geometry — frame=\(NSStringFromRect(windowFrame), privacy: .public) \
                    contentRect=\(NSStringFromRect(contentRect), privacy: .public) \
                    scale=\(filter.pointPixelScale, privacy: .public)
                    """)

                // `sourceRect` is measured from the content rect's OWN origin —
                // (0,0) is the top-left of the captured window, not a point in
                // screen space.
                //
                // `filter.contentRect` is reported in global coordinates (for a
                // window at {{435,276},{1050,639}} it reads back identically),
                // so adding `contentRect.origin` here re-applied the window's
                // screen position and shifted the crop by exactly that amount.
                // That was the Finder offset: 38pt for a window under the menu
                // bar, (435,276) for a floating one.
                //
                // The bug was invisible for display capture, where
                // `contentRect.origin` is (0,0) and the two forms agree.
                //
                // Sizes are taken as fractions of the window so the mapping
                // still holds if SCK ever reports a content rect that differs in
                // size from the window frame.
                let fx = (intersection.minX - windowFrame.minX) / windowFrame.width
                let fy = (intersection.minY - windowFrame.minY) / windowFrame.height
                let fw = intersection.width / windowFrame.width
                let fh = intersection.height / windowFrame.height

                var crop = CGRect(
                    x: fx * contentRect.width,
                    y: fy * contentRect.height,
                    width: fw * contentRect.width,
                    height: fh * contentRect.height
                )
                crop = crop.intersection(CGRect(origin: .zero, size: contentRect.size))

                if !crop.isNull, crop.width >= 2, crop.height >= 2 {
                    Log.capture.info("""
                        Binding highlighted window \(candidate.windowID, privacy: .public) \
                        (coverage \(Int(candidate.coverage * 100), privacy: .public)%) \
                        crop=\(NSStringFromRect(crop), privacy: .public)
                        """)
                    return .window(window, crop: crop)
                }
            }
            Log.capture.debug("Highlighted window no longer usable — falling back to display capture")
        }

        guard let display = try await ScreenPicker.display(for: selection.screen) else {
            Log.capture.error("Could not resolve an SCDisplay for the selection's screen")
            throw CaptureError.noTarget
        }
        return .display(display, crop: Self.sourceRect(forSelection: selection.rect, on: selection.screen))
    }

    /// Looks up the `SCWindow` matching a Core Graphics window number.
    private func windowForID(_ id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.windows.first { $0.windowID == id }
    }

    /// Converts a Cocoa global rect (bottom-left origin, primary display) into
    /// the Core Graphics global space (top-left origin) that `SCWindow.frame`
    /// and `CGWindowListCopyWindowInfo` both use.
    private static func cgGlobalRect(from cocoaRect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return cocoaRect }
        return CGRect(
            x: cocoaRect.minX,
            y: primary.frame.maxY - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
    }

    /// Stop the current capture session and release the stream.
    ///
    /// Safe to call when nothing is running. Releasing `stream` is what
    /// actually clears the purple screen-recording indicator — a retained but
    /// stopped `SCStream` keeps the session alive as far as the system is
    /// concerned.
    func stopCapture() async {
        guard stream != nil || isRunning else { return }

        Log.capture.info("stopCapture")

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                // -3808 ("stream already stopped") is expected when the system
                // tore it down first; it is not a failure to report.
                Log.capture.debug("stopCapture: \(Permissions.describe(error), privacy: .public)")
            }
        }

        self.stream = nil
        self.streamConfiguration = nil
        self.isRunning = false
        withRenderingLock { lastSurface = nil }

        await MainActor.run {
            appState?.isStreaming = false
            appState?.isPaused = false
        }
    }

    /// Rebuild the content filter so it excludes Glance's own windows.
    ///
    /// Called once the PiP panel exists: at `startCapture` time the panel has
    /// not been created yet, so it cannot be in the exclusion list, and without
    /// this second pass a PiP placed over the captured region mirrors itself.
    func refreshExcludedWindows() async {
        // Window-mode filters capture a single window and cannot include the PiP
        // panel, so there is nothing to exclude.
        guard let stream, let display = captureDisplay else { return }

        let excluded = (try? await ScreenPicker.glanceWindows()) ?? []
        guard excluded.count != excludedWindowCount else { return }
        excludedWindowCount = excluded.count

        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        do {
            try await stream.updateContentFilter(filter)
            Log.capture.info("Content filter refreshed — excluding \(excluded.count, privacy: .public) Glance window(s)")
        } catch {
            Log.capture.error("updateContentFilter failed: \(Permissions.describe(error), privacy: .public)")
        }
    }

    /// Update the captured sub-region on a **live** stream.
    ///
    /// - Parameter rect: The new region in Cocoa global coordinates.
    func updateSourceRect(_ rect: CGRect) async throws {
        guard let stream, let config = streamConfiguration, let screen = captureScreen else { return }

        let crop = Self.sourceRect(forSelection: rect, on: screen)
        guard crop.width >= 2, crop.height >= 2 else { return }

        selectionRect = rect
        config.sourceRect = crop
        let output = Self.outputSize(for: crop, scale: pointPixelScale)
        config.width = output.width
        config.height = output.height

        guard config.width > 0, config.height > 0 else { return }

        try await stream.updateConfiguration(config)
        Log.capture.debug("updateSourceRect -> \(NSStringFromRect(crop), privacy: .public)")
    }

    // MARK: - Geometry helpers

    /// Converts a Cocoa global rect into ScreenCaptureKit's `sourceRect` space.
    ///
    /// Cocoa's global space has its origin at the bottom-left of the *primary*
    /// display with Y growing upward. `sourceRect` is measured from the
    /// **top-left of the captured display** with Y growing downward. Both the
    /// origin shift and the flip are therefore relative to `screen.frame`:
    ///
    /// ```
    ///   x = selection.minX - screen.frame.minX
    ///   y = screen.frame.maxY - selection.maxY
    /// ```
    ///
    /// Using the primary screen's height for the flip (as the selection overlay
    /// previously did) only works when the target display *is* the primary one
    /// and its origin is exactly zero.
    private static func sourceRect(forSelection selection: CGRect, on screen: NSScreen) -> CGRect {
        let frame = screen.frame

        var crop = CGRect(
            x: selection.minX - frame.minX,
            y: frame.maxY - selection.maxY,
            width: selection.width,
            height: selection.height
        )

        // Clamp into the display. An out-of-bounds sourceRect is not an error to
        // SCK — it just yields black.
        let bounds = CGRect(origin: .zero, size: frame.size)
        crop = crop.intersection(bounds)
        return crop.isNull ? .zero : crop
    }

    /// Longest output edge, in backing pixels.
    ///
    /// The PiP panel is at most `GlanceWindowController.maxInitialWidth` (400pt)
    /// wide, and the largest zoom preset is 200%, so 400 x 2.0 x a 2x backing
    /// scale = 1600px is the most the panel can ever actually display. Capturing
    /// a 2498x1638 region at native resolution meant pushing 15.6 MB per frame —
    /// ~874 MB/s at 56fps — across the XPC boundary purely to have Core
    /// Animation scale it down again. SCK's own scaler is free (it runs in the
    /// compositor, on the GPU), so the downscale is better done there.
    ///
    /// This only ever reduces; a region smaller than the ceiling is captured
    /// pixel-for-pixel as before.
    static let maxOutputEdge: CGFloat = 1600

    /// Output size in backing pixels for a crop, capped to ``maxOutputEdge``
    /// and rounded to the even dimensions SCK requires.
    private static func outputSize(for crop: CGRect, scale: CGFloat) -> (width: Int, height: Int, capped: Bool) {
        let nativeWidth = crop.width * scale
        let nativeHeight = crop.height * scale
        let longest = max(nativeWidth, nativeHeight)

        let k = longest > maxOutputEdge ? maxOutputEdge / longest : 1
        return (
            evenPixels(nativeWidth * k),
            evenPixels(nativeHeight * k),
            k < 1
        )
    }

    /// SCK requires even output dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return max(0, rounded - (rounded % 2))
    }

    // MARK: - Workspace Monitoring

    /// Observe workspace notifications to detect when the source app is hidden,
    /// unhidden or terminated.
    private func setupWorkspaceMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter

        let hideObserver = nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.matchesSourceApp(notification) else { return }
            Log.capture.info("Source app hidden — pausing")
            self.appState?.isPaused = true
        }
        workspaceObservers.append(hideObserver)

        let unhideObserver = nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.matchesSourceApp(notification) else { return }
            Log.capture.info("Source app unhidden — resuming")
            self.appState?.isPaused = false
        }
        workspaceObservers.append(unhideObserver)

        let terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.matchesSourceApp(notification) else { return }
            Log.capture.info("Source app terminated — stopping capture")
            Task { [weak self] in await self?.stopCapture() }
        }
        workspaceObservers.append(terminateObserver)
    }

    private func matchesSourceApp(_ notification: Notification) -> Bool {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return false }
        return app.processIdentifier == appState?.sourceAppPID
    }
}

// MARK: - CaptureError

enum CaptureError: LocalizedError {
    case permissionDenied
    case invalidGeometry
    case noTarget

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted. Enable Glance in "
                 + "System Settings → Privacy & Security → Screen Recording, then relaunch."
        case .invalidGeometry:
            return "The selected region produced an empty capture rectangle."
        case .noTarget:
            return "Could not find a window or display to capture under the selection."
        }
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {

    /// Called by ScreenCaptureKit on `captureQueue` for each new frame.
    ///
    /// Frames are dropped while a previous one is still being presented, so a
    /// slow compositor cannot build an unbounded backlog on the main queue.
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }

        // SCK emits status-only buffers (idle, blank, suspended) with no image
        // buffer. Treating those as frames is harmless, but distinguishing them
        // in the log is the difference between "the stream is dead" and "the
        // window simply isn't redrawing".
        // SCK marks every buffer with a frame status. Only `.complete` carries
        // new pixels; `.idle` means "nothing changed, keep showing the last
        // frame", and `.blank`/`.suspended` carry no image at all. Treating
        // those as errors is what filled the log with "status-only frame" once
        // per second on a static window.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue),
           status != .complete {
            if status != .idle {
                logSparse("Frame status \(status.rawValue) (not .complete) — no pixels this cycle")
            }
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        renderingLock.lock()
        receivedFrameCount &+= 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        let count = receivedFrameCount
        if isProcessingFrame {
            renderingLock.unlock()
            return
        }
        isProcessingFrame = true
        renderingLock.unlock()

        if count == 1 {
            Log.capture.info("First sample buffer received: \(CVPixelBufferGetWidth(pixelBuffer), privacy: .public)x\(CVPixelBufferGetHeight(pixelBuffer), privacy: .public)")
        } else if count % 600 == 0 {
            // Roughly every 10s at 60fps. Footprint should be flat across a long
            // session; a rising number means frames are being retained
            // somewhere they should not be.
            Log.capture.debug("""
                \(count, privacy: .public) frames — \
                \(Self.footprintMB(), privacy: .public) MB footprint
                """)
        }

        // Zero-copy handle to the WindowServer's own GPU memory.
        // `takeUnretainedValue()` (not `unsafeBitCast`) is what gives ARC a
        // properly managed reference — the previous bitcast produced an
        // unretained object that could be recycled by SCK mid-frame.
        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else {
            Log.capture.error("CVPixelBufferGetIOSurface returned nil — frame cannot be presented")
            renderingLock.lock()
            isProcessingFrame = false
            renderingLock.unlock()
            return
        }
        let surface = surfaceRef.takeUnretainedValue() as IOSurface
        withRenderingLock { lastSurface = surface }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer {
                self.renderingLock.lock()
                self.isProcessingFrame = false
                self.renderingLock.unlock()
            }

            // NOTE: the surface is deliberately NOT stored on AppState.
            //
            // `AppState` is `@Observable`, so assigning to it 60 times a second
            // ran the observation machinery on every frame — registrar lookups
            // and change notifications — for a property no view ever read. The
            // renderer is fed directly; `lastSurface` (plain storage, under the
            // lock) covers the replay case.
            //
            // A nil renderer here is normal for the first frames; the surface is
            // buffered above and replayed by `attachRenderer(_:)`.
            self.onFrameReceived?(surface)
        }
    }

    /// Resident memory footprint in MB, for the streaming instrumentation.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// Emits at most one message per second so a per-frame condition doesn't
    /// flood the log at 60 Hz.
    private func logSparse(_ message: String) {
        struct Throttle { static var last: CFAbsoluteTime = 0 }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - Throttle.last > 1.0 else { return }
        Throttle.last = now
        Log.capture.debug("\(message, privacy: .public)")
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {

    /// Called when the stream terminates without us asking.
    ///
    /// Two very different situations arrive through this one callback: the user
    /// pressing "Stop Sharing" in the system's recording pill, and an actual
    /// capture failure. Only the second is worth reporting.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let deliberate = Permissions.isDeliberateStop(error)
        let description = Permissions.describe(error)

        if deliberate {
            Log.capture.info("Stream ended deliberately — \(description, privacy: .public)")
        } else {
            Log.capture.error("Stream stopped with error — \(description, privacy: .public)")
        }

        // Release the stream here as well as in stopCapture(). The session is
        // already dead; holding the object keeps the system's recording
        // indicator lit until something else happens to clear it.
        self.stream = nil
        self.streamConfiguration = nil

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.appState?.isStreaming = false
            self.appState?.isPaused = false
            // A deliberate stop is not a failure, so it leaves no message
            // behind in the menu.
            self.appState?.errorMessage = deliberate ? nil : description
            self.onStreamEnded?()
        }
    }
}
