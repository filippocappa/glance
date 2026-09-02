import ApplicationServices
import AppKit
import SwiftUI

// MARK: - GlancePanel
// ─────────────────────────────────────────────────────────────────────────────
// A borderless, non-activating floating panel.
//
// `canBecomeKey` is required: without it a borderless panel never becomes key,
// and AppKit will not route mouse-drag sequences into its content view — the
// SwiftUI DragGesture would fire `onChanged` once and then go silent.
// `.nonactivatingPanel` keeps Glance from stealing focus from the source app
// when that happens.
// ─────────────────────────────────────────────────────────────────────────────

final class GlancePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - FirstMouseHostingView
// ─────────────────────────────────────────────────────────────────────────────
// Glance is an LSUIElement agent and is therefore never the active application.
// Without `acceptsFirstMouse`, AppKit swallows the first click in a window
// belonging to an inactive app — which meant the first drag attempt on the PiP
// always did nothing.
// ─────────────────────────────────────────────────────────────────────────────

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// When non-nil, only points inside this rect (in view coordinates) are
    /// hit-testable; everything else passes through.
    ///
    /// This is the second half of Ghost Mode. `ignoresMouseEvents` is a
    /// *window* flag — with it set the window is handed no events at all, so a
    /// hitTest override alone cannot keep a badge clickable. The controller
    /// therefore briefly clears `ignoresMouseEvents` while the cursor is over
    /// the badge, and this override makes sure that during those moments only
    /// the badge can be hit, never the video underneath it.
    var ghostHitRect: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let ghostHitRect, !ghostHitRect.contains(point) { return nil }
        return super.hitTest(point)
    }
}

// MARK: - HoverTrackingView
// ─────────────────────────────────────────────────────────────────────────────
// Reports mouse exit from the PiP window using an NSTrackingArea with
// `.activeAlways`, which — unlike SwiftUI's `.onHover` — keeps firing while the
// owning app is inactive.
// ─────────────────────────────────────────────────────────────────────────────

final class HoverTrackingView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent) { onExited?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // tracking only, never steals clicks
}

struct HoverTracker: NSViewRepresentable {
    var onEntered: () -> Void
    var onExited: () -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onEntered = onEntered
        view.onExited = onExited
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onExited = onExited
    }
}

// MARK: - GlanceWindowController
// ─────────────────────────────────────────────────────────────────────────────
// Owns the single floating PiP panel.
//
// Ghost mode (click-through when the cursor is elsewhere) is driven by events,
// not by polling. The previous implementation ran a 20 Hz `Timer` that read
// `NSEvent.mouseLocation` and flipped `ignoresMouseEvents` — that is what caused
// the drag ghosting: for up to 50 ms after the cursor entered the window the
// panel was still click-through, so mouse-down landed on whatever was behind it.
//
// Instead:
//   * a **global** mouse-moved monitor notices the cursor entering the panel's
//     frame while the panel is still click-through, and
//   * an **NSTrackingArea** (`.activeAlways`) inside the panel notices it
//     leaving.
// Both are exact; neither costs anything while the cursor is idle.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class GlanceWindowController: NSObject, NSWindowDelegate {

    // MARK: - Properties

    private var panel: GlancePanel?
    private let appState: AppState
    private let captureEngine: CaptureEngine

    /// Global mouse-moved monitor used to detect cursor entry while the panel
    /// is in click-through mode (events over a click-through window are
    /// delivered to the app underneath, so only a global monitor can see them).
    private var globalMouseMonitor: Any?

    /// Live-resize notification tokens.
    private var resizeObservers: [NSObjectProtocol] = []

    /// The panel's root hosting view, retained so Ghost Mode can adjust its
    /// hit-testing region.
    private weak var hostingView: FirstMouseHostingView<PiPContentView>?

    /// Size and inset of the Ghost Mode exit badge, in points.
    private static let badgeSize: CGFloat = 34
    private static let badgeInset: CGFloat = 6

    /// Opacity the panel fades to in Ghost Mode.
    ///
    /// Low enough that text and windows behind it stay readable. The accent
    /// outline drawn by `PiPContentView` compensates, so the panel's bounds
    /// remain findable at this opacity.
    private static let ghostAlpha: CGFloat = 0.32

    // MARK: - Sizing

    /// Smallest PiP the user can shrink to.
    static let minPanelWidth: CGFloat = 160
    static let minPanelHeight: CGFloat = 100

    /// Largest initial width; the height follows from the capture's ratio.
    static let maxInitialWidth: CGFloat = 400

    /// Initial panel size for a capture of `captureSize`, preserving its exact
    /// aspect ratio and never dropping below the minimums.
    static func initialPanelSize(for captureSize: CGSize) -> CGSize {
        // Guard the ratio: a zero dimension would make this NaN, and AppKit
        // raises on a NaN frame rather than ignoring it.
        guard captureSize.width > 0, captureSize.height > 0 else {
            return CGSize(width: minPanelWidth, height: minPanelHeight)
        }
        let width = min(maxInitialWidth, captureSize.width)
        return clampToMinimum(
            CGSize(width: width, height: width * captureSize.height / captureSize.width),
            aspect: captureSize
        )
    }

    /// Scales `size` up until both dimensions clear the minimums, keeping the
    /// aspect ratio of `aspect` exactly.
    ///
    /// Scaling (rather than clamping each axis independently) matters because
    /// the panel has a `contentAspectRatio` constraint: handing AppKit a
    /// minimum size whose ratio disagrees with that constraint gives its
    /// resize solver two incompatible rules to satisfy.
    static func clampToMinimum(_ size: CGSize, aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0, size.width > 0, size.height > 0 else {
            return CGSize(width: minPanelWidth, height: minPanelHeight)
        }
        let scale = max(1, max(minPanelWidth / size.width, minPanelHeight / size.height))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    // MARK: - Initialization

    init(appState: AppState, captureEngine: CaptureEngine) {
        self.appState = appState
        self.captureEngine = captureEngine
        super.init()
    }

    // MARK: - NSWindowDelegate

    /// Constrains every interactive resize to the capture's aspect ratio, the
    /// minimum panel size, and the screen's visible frame — in that order.
    ///
    /// Returning an already-valid size is what keeps AppKit from having to
    /// solve anything, so no layout re-entry can occur.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        sanitizedSize(frameSize, on: sender.screen)
    }

    /// Clamp a proposed size to something AppKit can always satisfy.
    ///
    /// Every `setFrame` in this class goes through here. A non-finite or
    /// non-positive dimension reaching AppKit is an immediate hard failure, and
    /// a size larger than the screen fights the window server's own clamping.
    func sanitizedSize(_ proposed: NSSize, on screen: NSScreen?) -> NSSize {
        let capture = appState.captureSize
        let ratio: CGFloat = (capture.width > 0 && capture.height > 0)
            ? capture.width / capture.height
            : 16.0 / 9.0

        // Reject NaN/infinity outright rather than propagating it.
        var width = proposed.width.isFinite ? proposed.width : Self.minPanelWidth
        guard ratio.isFinite, ratio > 0 else {
            return NSSize(width: Self.minPanelWidth, height: Self.minPanelHeight)
        }

        // Width is the driving dimension; height always follows from the ratio,
        // so the panel can never drift off the capture's proportions.
        width = max(width, Self.minPanelWidth)
        width = max(width, Self.minPanelHeight * ratio)

        if let visible = screen?.visibleFrame.size {
            width = min(width, max(Self.minPanelWidth, visible.width - SnapEngine.margin * 2))
            let maxWidthForHeight = max(Self.minPanelWidth, (visible.height - SnapEngine.margin * 2) * ratio)
            width = min(width, maxWidthForHeight)
        }

        let height = width / ratio
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return NSSize(width: Self.minPanelWidth, height: Self.minPanelHeight)
        }
        return NSSize(width: width, height: height)
    }

    // MARK: - Show / Close

    /// Show the PiP window with the given initial size and position.
    func show(size: CGSize, position: CGPoint) {
        assert(Thread.isMainThread, "GlanceWindowController.show must run on the main thread")

        let panel = GlancePanel(
            contentRect: NSRect(origin: position, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false                 // movement is handled by DragGesture
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // `.none`, not `.utilityWindow`: any built-in frame animation competes
        // with live resize and with the snap spring, which reads as judder.
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false          // an LSUIElement app deactivates constantly
        panel.isReleasedWhenClosed = false

        // The aspect ratio is enforced by `windowWillResize(_:to:)` below, NOT
        // by `contentAspectRatio`.
        //
        // Setting `contentAspectRatio` alongside `contentMinSize` gives AppKit's
        // resize solver two rules to reconcile, and reconciling them re-enters
        // layout. Combined with `setFrame` being called synchronously from a
        // SwiftUI `.onChange`, that recursion ran the stack out and killed the
        // process with no exception and no crash report. Doing the arithmetic
        // ourselves is deterministic and cannot recurse.
        panel.delegate = self

        observeLiveResize(of: panel)

        // The panel accepts mouse events from the moment it appears.
        //
        // It used to start click-through and only become interactive once a
        // GLOBAL mouse monitor noticed the cursor enter. A global monitor only
        // sees events delivered to *other* applications, so the sequence was:
        // cursor enters -> the click lands on the app underneath -> the monitor
        // fires -> the panel becomes interactive. The first click after entering
        // was therefore routinely lost, and every later one waited on a
        // main-queue hop. Pass-through is now exclusively Ghost Mode's job,
        // which is explicit, sticky, and has its own hotkey.
        panel.ignoresMouseEvents = false

        let contentView = PiPContentView(
            appState: appState,
            captureEngine: captureEngine,
            window: panel,
            onClose: { [weak self] in self?.close() },
            onBringToFront: { [weak self] in self?.bringSourceToFront() },
            onZoomLevelChanged: { [weak self] newZoom in self?.resizeWindow(toZoom: newZoom) },
            onHoverEntered: { [weak self] in self?.setHovering(true) },
            onHoverExited: { [weak self] in self?.setHovering(false) },
            onToggleGhostMode: { [weak self] in self?.toggleGhostMode() }
        )

        let hostingView = FirstMouseHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.hostingView = hostingView

        self.panel = panel

        // Snap to the nearest corner *before* ordering in, so the panel doesn't
        // visibly jump from its provisional position on the first frame.
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrameOrigin(SnapEngine.initialPosition(for: panel.frame, on: screen))

        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: Glance is a
        // background agent, so it is never the active app and AppKit will refuse
        // an ordinary orderFront from an inactive application.
        panel.orderFrontRegardless()

        Log.window.info("""
            PiP panel shown — frame=\(NSStringFromRect(panel.frame), privacy: .public) \
            level=\(panel.level.rawValue, privacy: .public) \
            visible=\(panel.isVisible, privacy: .public) \
            screen=\(NSStringFromRect(screen.frame), privacy: .public)
            """)

        startHoverMonitoring()

        // The panel did not exist when the content filter was built, so it is
        // still inside the captured region. Rebuild the filter now to exclude
        // it — otherwise the PiP mirrors itself when it overlaps the selection.
        Task { await captureEngine.refreshExcludedWindows() }
    }

    /// Close the PiP window and stop capture.
    func close() {
        Log.window.info("Closing PiP panel")

        stopHoverMonitoring()
        SnapEngine.cancelAnimation()

        for observer in resizeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        resizeObservers.removeAll()

        captureEngine.onFrameReceived = nil

        Task { await captureEngine.stopCapture() }

        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil

        appState.reset()
    }

    // MARK: - Frame application

    /// Guards against re-entering `setFrame` from within a layout pass.
    private var isApplyingFrame = false

    /// Applies a sanitised size to the panel, off the current SwiftUI update.
    ///
    /// The hop through `DispatchQueue.main.async` is the important part: calling
    /// `setFrame` synchronously from a SwiftUI `.onChange` resizes the hosting
    /// view mid-update, which schedules another update, which calls back in.
    private func applySize(_ size: NSSize, animated: Bool) {
        // The panel is re-read inside the async block; only its existence and
        // the re-entry flag matter here.
        guard panel != nil, !isApplyingFrame else { return }
        isApplyingFrame = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            defer { self.isApplyingFrame = false }

            let safe = self.sanitizedSize(size, on: panel.screen ?? NSScreen.main)
            guard safe.width > 0, safe.height > 0 else { return }

            SnapEngine.cancelAnimation()
            panel.setFrame(NSRect(origin: panel.frame.origin, size: safe), display: true)
            self.appState.windowSize = safe

            // Resizing can push the panel off-screen; re-snap only when it is
            // already near a corner, otherwise just keep it fully visible.
            let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let target = SnapEngine.snapPosition(for: panel.frame, on: screen)
                ?? SnapEngine.clampOnScreen(panel.frame, on: screen)
            if animated {
                SnapEngine.animateSpring(window: panel, to: target, on: screen)
            } else {
                panel.setFrameOrigin(target)
            }
        }
    }

    // MARK: - Ghost Mode

    /// Earliest time the next Ghost Mode toggle will be honoured.
    private var ghostToggleUnlockTime: CFTimeInterval = 0

    /// Minimum gap between honoured toggles.
    ///
    /// The alpha cross-fade and the `ignoresMouseEvents` flip are not atomic
    /// with respect to each other. Spamming the hotkey interleaved them, and a
    /// pair that landed out of order left the panel dim but opaque to clicks,
    /// or interactive but with the HUD hidden — either way, unusable. Rejecting
    /// presses until the previous transition has settled removes the window in
    /// which that can happen.
    private static let ghostToggleDebounce: CFTimeInterval = 0.25

    /// Flip Ghost Mode, ignoring presses that arrive mid-transition.
    func toggleGhostMode() {
        let now = CACurrentMediaTime()
        guard now >= ghostToggleUnlockTime else {
            Log.window.debug("Ghost Mode toggle debounced")
            return
        }
        ghostToggleUnlockTime = now + Self.ghostToggleDebounce
        setGhostMode(!appState.isGhostMode)
    }

    /// Engage or release Ghost Mode.
    ///
    /// Engaged, the panel drops to ``ghostAlpha`` and stops receiving mouse
    /// events entirely, so clicks land on the app behind it. The only ways back
    /// out are the global hotkey, the menu bar item, and the corner exit badge
    /// (see ``updateGhostHitTesting(cursorAt:)``).
    func setGhostMode(_ enabled: Bool) {
        guard let panel, appState.isGhostMode != enabled else { return }
        appState.isGhostMode = enabled

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = enabled ? Self.ghostAlpha : 1.0
        } completionHandler: { [weak self] in
            // Land on the exact end value. An interrupted implicit animation
            // can otherwise leave alpha part-way, which reads as a stuck
            // half-ghosted panel.
            //
            // NSAnimationContext calls this on the main thread but types the
            // closure as Sendable, so the isolation has to be asserted.
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                panel.alphaValue = self.appState.isGhostMode ? Self.ghostAlpha : 1.0
            }
        }

        if enabled {
            panel.ignoresMouseEvents = true
            appState.isHovering = false
            hostingView?.ghostHitRect = badgeRectInView()
        } else {
            // Restore unconditionally rather than deriving from cursor
            // position: these two are the state that gets stranded, so they are
            // reset first and asked questions afterwards.
            hostingView?.ghostHitRect = nil
            panel.ignoresMouseEvents = false

            // If the cursor is already inside, adopt the hover state now. The
            // global monitor only fires on movement, so a stationary cursor
            // would otherwise leave the HUD hidden over an interactive panel.
            // The panel is interactive whenever Ghost Mode is off, so there is
            // no cursor-dependent branch to get wrong here.
            let inside = panel.frame.contains(NSEvent.mouseLocation)
            withAnimation(.easeInOut(duration: 0.15)) { appState.isHovering = inside }
        }

        Log.window.info("Ghost Mode \(enabled ? "engaged" : "released", privacy: .public)")
    }

    /// The exit badge, in the hosting view's coordinate space (bottom-left origin).
    private func badgeRectInView() -> NSRect {
        guard let panel else { return .zero }
        let h = panel.contentView?.bounds.height ?? panel.frame.height
        return NSRect(
            x: Self.badgeInset,
            y: h - Self.badgeSize - Self.badgeInset,
            width: Self.badgeSize,
            height: Self.badgeSize
        )
    }

    /// The exit badge in global screen coordinates.
    private func badgeRectOnScreen() -> NSRect {
        guard let panel else { return .zero }
        return NSRect(
            x: panel.frame.minX + Self.badgeInset,
            y: panel.frame.maxY - Self.badgeSize - Self.badgeInset,
            width: Self.badgeSize,
            height: Self.badgeSize
        )
    }

    /// While in Ghost Mode, briefly make the panel interactive when — and only
    /// when — the cursor is over the exit badge.
    private func updateGhostHitTesting(cursorAt location: NSPoint) {
        guard let panel, appState.isGhostMode else { return }
        hostingView?.ghostHitRect = badgeRectInView()

        let overBadge = badgeRectOnScreen().contains(location)
        if panel.ignoresMouseEvents == overBadge {
            panel.ignoresMouseEvents = !overBadge
        }
    }

    // MARK: - Live Resize

    /// Suspends snapping and click-through toggling for the duration of an
    /// AppKit live resize, and snaps once when the user lets go.
    ///
    /// The stream is deliberately NOT reconfigured here. It keeps capturing at
    /// the selected source resolution and the compositor rescales the IOSurface
    /// on the GPU — reconfiguring `SCStreamConfiguration` on every resize tick
    /// would tear down and rebuild the capture pipeline dozens of times a second.
    private func observeLiveResize(of panel: NSPanel) {
        let nc = NotificationCenter.default

        resizeObservers.append(nc.addObserver(
            forName: NSWindow.willStartLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Kill any in-flight snap before AppKit starts writing the frame.
                SnapEngine.cancelAnimation()
                self.appState.isResizing = true
            }
        })

        resizeObservers.append(nc.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.appState.isResizing = false
                self.appState.windowSize = panel.frame.size

                // Snap only now that the mouse is up, and only if the panel
                // ended up near a corner. The size itself is already valid —
                // windowWillResize sanitised every step of it.
                let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
                if let target = SnapEngine.snapPosition(for: panel.frame, on: screen) {
                    SnapEngine.animateSpring(window: panel, to: target, on: screen)
                }
                Log.window.debug("Live resize ended — size \(NSStringFromSize(panel.frame.size), privacy: .public)")
            }
        })
    }

    // MARK: - Ghost Mode (event-driven hover)

    /// Watches the cursor while Ghost Mode is engaged, so the exit badge can be
    /// made clickable as it passes over.
    ///
    /// Only needed in Ghost Mode: the panel is click-through then, so its events
    /// go to the app underneath and a global monitor is the only way to see
    /// them. Outside Ghost Mode the panel receives its own events and hover is
    /// driven by an NSTrackingArea instead, which is both lower latency and not
    /// subject to the monitor's delivery hop.
    private func startHoverMonitoring() {
        stopHoverMonitoring()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.appState.isGhostMode else { return }
                self.updateGhostHitTesting(cursorAt: NSEvent.mouseLocation)
            }
        }
    }

    private func stopHoverMonitoring() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        globalMouseMonitor = nil
    }

    /// Enter or leave interactive mode.
    fileprivate func setHovering(_ hovering: Bool) {
        guard appState.isHovering != hovering, !appState.isGhostMode else { return }
        // Keep the HUD up for the whole of a drag or resize, even if the cursor
        // strays outside the frame mid-gesture.
        if !hovering && (appState.isDragging || appState.isResizing) { return }

        // Purely visual now. Mouse delivery is no longer tied to hover, so a
        // click never has to wait for this to resolve.
        withAnimation(.easeInOut(duration: 0.15)) {
            appState.isHovering = hovering
        }
    }

    // MARK: - Resizing

    private func resizeWindow(toZoom zoom: CGFloat) {
        // Derive from the ACTUAL capture crop, so zoom can never drift the panel
        // off the stream's aspect ratio.
        let capture = appState.captureSize
        guard capture.width > 0, capture.height > 0, zoom.isFinite, zoom > 0 else {
            Log.window.error("resizeWindow ignored — captureSize=\(NSStringFromSize(capture), privacy: .public) zoom=\(zoom, privacy: .public)")
            return
        }

        // Resizing the panel does NOT touch the stream. SCStream keeps capturing
        // at the source resolution and Core Animation rescales the IOSurface on
        // the GPU; reconfiguring the stream per resize would tear down and
        // rebuild the capture pipeline dozens of times a second.
        let base = Self.initialPanelSize(for: capture)
        applySize(NSSize(width: base.width * zoom, height: base.height * zoom), animated: true)
    }

    // MARK: - Source App Interaction

    /// Bring the captured window's application forward.
    ///
    /// `activate(options: [.activateIgnoringOtherApps])` is deprecated on
    /// macOS 14+, where the plain `activate()` already ignores other apps for a
    /// foreground-requested activation. Both are kept so the behaviour is
    /// identical on either OS rather than silently doing nothing on one.
    ///
    /// Raising the *specific* window (rather than just the app) needs the
    /// Accessibility API. We only attempt it when the process is already
    /// trusted — Glance never prompts for Accessibility, since it is a
    /// nice-to-have and the app is fully functional without it.
    private func bringSourceToFront() {
        guard let pid = appState.sourceAppPID,
              let app = NSRunningApplication(processIdentifier: pid) else {
            Log.window.error("bringSourceToFront: no source application recorded")
            return
        }

        let activated: Bool
        if #available(macOS 14.0, *) {
            activated = app.activate()
        } else {
            activated = app.activate(options: [.activateIgnoringOtherApps])
        }
        Log.window.info("Activated source app pid=\(pid, privacy: .public) -> \(activated, privacy: .public)")

        raiseSourceWindow(pid: pid)
    }

    /// De-miniaturises and raises the captured window via Accessibility.
    ///
    /// Activating the process alone does nothing for a window sitting in the
    /// Dock — AppKit offers no public way to un-minimise another app's window,
    /// so `kAXMinimizedAttribute` is the only route. That requires the
    /// Accessibility permission, which we ask for here (and only here, on an
    /// explicit user action) rather than at launch.
    private func raiseSourceWindow(pid: pid_t) {
        guard ensureAccessibilityPermission() else {
            Log.window.info("Accessibility not granted — activated the app, but cannot un-minimise its window")
            return
        }

        // An app hidden with Cmd-H needs unhiding before its windows respond.
        NSRunningApplication(processIdentifier: pid)?.unhide()

        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else {
            Log.window.debug("No accessible windows for pid \(pid, privacy: .public)")
            return
        }

        let target = matchTargetWindow(among: windows) ?? windows[0]

        // Un-minimise first: a minimised window cannot be raised or focused.
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            Log.window.info("Un-minimised source window")
        }

        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axApp, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Finds the AX element for the window Glance is actually capturing.
    ///
    /// The Accessibility API exposes no CGWindowID, so the recorded title is the
    /// only public way to correlate the two. Falls back to the frontmost window
    /// when the title is empty or ambiguous.
    private func matchTargetWindow(among windows: [AXUIElement]) -> AXUIElement? {
        guard let wanted = appState.sourceWindowTitle, !wanted.isEmpty else { return nil }
        for window in windows {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let string = title as? String else { continue }
            if string == wanted { return window }
        }
        return nil
    }

    /// Returns whether Accessibility is available, prompting once if not.
    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() { return true }

        // Prompting is only appropriate because this runs from a deliberate
        // button press. The system shows its own dialog and remembers the answer.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.window.info("Requested Accessibility permission for window raising")
        }
        return trusted
    }
}

// MARK: - PiPContentView
// ─────────────────────────────────────────────────────────────────────────────
// Root SwiftUI view for the PiP panel: video layer, paused overlay, hover
// controls, and the drag-to-move / snap gesture.
// ─────────────────────────────────────────────────────────────────────────────

struct PiPContentView: View {
    let appState: AppState
    let captureEngine: CaptureEngine
    let window: NSWindow

    var onClose: () -> Void
    var onBringToFront: () -> Void
    var onZoomLevelChanged: (CGFloat) -> Void
    var onHoverEntered: () -> Void
    var onHoverExited: () -> Void
    var onToggleGhostMode: () -> Void

    /// Window origin and cursor position recorded at the start of a drag.
    ///
    /// The cursor is tracked in SCREEN coordinates via `NSEvent.mouseLocation`,
    /// not through `DragGesture.translation`. The gesture lives inside the very
    /// window being moved, so each `setFrameOrigin` shifts the gesture's own
    /// coordinate space and the next translation is measured against a moved
    /// reference — a feedback loop that showed up as jitter during the drag.
    /// Screen coordinates are an absolute frame that the window cannot perturb.
    @State private var dragAnchor: (windowOrigin: CGPoint, mouse: CGPoint)? = nil

    /// Recent cursor samples, newest last, used to measure release velocity.
    ///
    /// Velocity is taken over a short trailing window rather than from the last
    /// two events: consecutive samples can be a single frame apart, where a one
    /// pixel jitter reads as hundreds of points per second.
    @State private var velocitySamples: [(time: CFTimeInterval, point: CGPoint)] = []

    /// Width of the border band reserved for AppKit's live-resize handles.
    ///
    /// A drag that begins inside this band is a resize, not a move, so the move
    /// gesture must ignore it — otherwise a corner drag repositions and resizes
    /// the panel at the same time and the window chases the cursor.
    private let resizeMargin: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // GPU video stream.
                PiPVideoView(captureEngine: captureEngine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if appState.isPaused {
                    PausedOverlayView()
                }

                HoverControlsView(
                    isHovering: appState.isHovering,
                    isGhostMode: appState.isGhostMode,
                    onClose: onClose,
                    onBringToFront: onBringToFront,
                    onToggleGhostMode: onToggleGhostMode,
                    zoomLevel: Binding(
                        get: { appState.zoomLevel },
                        set: { appState.zoomLevel = $0 }
                    )
                )

                // Ghost Mode exit badge. Always visible while ghosting (hover
                // controls are unreachable then, since the panel ignores the
                // mouse everywhere except this badge).
                if appState.isGhostMode {
                    GhostExitBadge(action: onToggleGhostMode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                }

                // Reports cursor exit so the panel can return to click-through mode.
                HoverTracker(onEntered: onHoverEntered, onExited: onHoverExited)
                    .allowsHitTesting(false)
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // In Ghost Mode the panel drops to ~32% opacity, so without an
            // outline its edges vanish against busy content. The accent border
            // keeps it findable and signals that clicks are passing through.
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        appState.isGhostMode ? Theme.accent.opacity(0.95) : Color.clear,
                        lineWidth: 2
                    )
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Hand the gesture to AppKit if it started on a resize
                        // edge, and stay out of the way for the whole drag.
                        guard !appState.isResizing,
                              !isInResizeBand(value.startLocation, in: geometry.size)
                        else { return }

                        let mouse = NSEvent.mouseLocation

                        if dragAnchor == nil {
                            dragAnchor = (window.frame.origin, mouse)
                            appState.isDragging = true
                            velocitySamples = []
                            // A snap still settling would otherwise keep writing
                            // the origin underneath the drag.
                            SnapEngine.cancelAnimation()
                        }
                        guard let anchor = dragAnchor else { return }

                        recordSample(mouse)

                        // Pure 1:1 cursor tracking. No snapping, no clamping and
                        // no animation runs while the mouse is down — the window
                        // simply follows the delta.
                        window.setFrameOrigin(CGPoint(
                            x: anchor.windowOrigin.x + (mouse.x - anchor.mouse.x),
                            y: anchor.windowOrigin.y + (mouse.y - anchor.mouse.y)
                        ))
                    }
                    .onEnded { _ in
                        guard let startOrigin = dragAnchor?.windowOrigin else { return }
                        dragAnchor = nil
                        appState.isDragging = false

                        // Everything positional happens here, on mouse-up: the
                        // release velocity chooses the target and seeds the
                        // spring that carries the window to it.
                        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
                        SnapEngine.release(
                            window: window,
                            velocity: releaseVelocity(),
                            from: startOrigin,
                            on: screen
                        )
                        velocitySamples = []
                    }
            )
            .onChange(of: appState.zoomLevel) { _, newValue in
                onZoomLevelChanged(newValue)
            }
        }
    }

    /// Appends a cursor sample and drops anything older than the measurement
    /// window, so the buffer stays at a handful of entries.
    private func recordSample(_ point: CGPoint) {
        let now = CACurrentMediaTime()
        velocitySamples.append((now, point))
        velocitySamples.removeAll { now - $0.time > Self.velocityWindow }
    }

    /// Cursor velocity at release, in points per second.
    ///
    /// Measured from the oldest sample still inside the trailing window to the
    /// newest. If the cursor was held still before letting go the buffer holds
    /// only near-identical points, which correctly yields ~zero and leaves the
    /// window where it was dropped.
    private func releaseVelocity() -> CGVector {
        guard let newest = velocitySamples.last,
              let oldest = velocitySamples.first,
              case let dt = newest.time - oldest.time,
              dt > 0.004
        else { return .zero }

        var vx = (newest.point.x - oldest.point.x) / CGFloat(dt)
        var vy = (newest.point.y - oldest.point.y) / CGFloat(dt)

        // Clamp: one stray sample across a dropped frame can otherwise report
        // thousands of points per second and fling the window at the wall.
        let speed = hypot(vx, vy)
        if speed > SnapEngine.maxFlickSpeed {
            let scale = SnapEngine.maxFlickSpeed / speed
            vx *= scale
            vy *= scale
        }
        return CGVector(dx: vx, dy: vy)
    }

    /// Trailing window over which release velocity is measured.
    private static let velocityWindow: CFTimeInterval = 0.09

    /// Whether `point` (in view coordinates) falls in the resize border band.
    private func isInResizeBand(_ point: CGPoint, in size: CGSize) -> Bool {
        point.x < resizeMargin
            || point.y < resizeMargin
            || point.x > size.width - resizeMargin
            || point.y > size.height - resizeMargin
    }
}
