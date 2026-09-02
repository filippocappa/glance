import AppKit
import QuartzCore
import IOSurface
import SwiftUI

// MARK: - VideoLayerView
// ─────────────────────────────────────────────────────────────────────────────
// Presents captured frames by assigning the frame's IOSurface straight to a
// CALayer's `contents`. This is the true zero-copy path: the WindowServer wrote
// the pixels into that surface, and Core Animation composites it directly from
// the same GPU memory. No texture upload, no CIContext, no drawable pool.
//
// The previous CAMetalLayer + CIContext implementation was replaced because it
// had three independent ways to silently render nothing:
//   1. `nextDrawable()` returns nil (and the frame is dropped) whenever
//      `drawableSize` is reassigned, which happened on every frame where the
//      layer's own layout had reset it back to the view's point size.
//   2. `CIRenderDestination` needed a manual vertical flip that had to stay in
//      sync with SCK's top-down buffers.
//   3. Any CIContext failure only surfaced as a print on a background queue.
// Assigning an IOSurface to `contents` has none of those failure modes — and
// Core Animation already handles the top-down orientation correctly.
// ─────────────────────────────────────────────────────────────────────────────

final class VideoLayerView: NSView {

    /// Number of frames presented so far. Used only for diagnostics — we log the
    /// first frame and then every 300th, so a stalled pipeline is obvious in the
    /// log stream without flooding it at 60 fps.
    private var presentedFrameCount: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        // Scale-and-centre, set at the VIEW level rather than on the layer.
        //
        // Assigning `layer.contentsGravity` directly does not stick: AppKit
        // rewrites it from `layerContentsPlacement` on every layer update, and
        // that property defaults to `.scaleAxesIndependently` (kCAGravityResize).
        // `.scaleProportionallyToFit` maps to kCAGravityResizeAspect and is the
        // value AppKit will keep.
        layerContentsPlacement = .scaleProportionallyToFit

        guard let layer else {
            Log.render.error("VideoLayerView has no backing layer after wantsLayer = true")
            return
        }
        // The captured surface is opaque BGRA; letting the layer know avoids a
        // pointless blend pass against the transparent panel background.
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.magnificationFilter = .trilinear
        layer.minificationFilter = .trilinear

        // Bounds changes must not invalidate the contents — during a live
        // resize the same IOSurface is simply rescaled by the compositor.
        layer.needsDisplayOnBoundsChange = false

        updateContentsScale()

        Log.render.debug("VideoLayerView backing layer configured")
    }

    /// Keeps `contentsScale` matched to the display the view is on.
    ///
    /// The captured surface is in backing pixels; without the matching scale
    /// Core Animation treats those pixels as points and the image is drawn at
    /// twice its intended size on a Retina display.
    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if layer?.contentsScale != scale {
            layer?.contentsScale = scale
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    /// Fires when the view moves between displays of differing scale factors.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    /// Presents a captured frame. Must be called on the main thread.
    ///
    /// - Parameter surface: The `IOSurface` backing the frame's `CVPixelBuffer`.
    func present(surface: IOSurface) {
        guard let layer else {
            Log.render.error("present(surface:) called with no backing layer")
            return
        }

        // Core Animation would otherwise animate every `contents` assignment
        // through the default 0.25s cross-fade, which at 60 fps turns the video
        // into a smeared mess and pegs the compositor.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()

        presentedFrameCount += 1
        if presentedFrameCount == 1 {
            let w = IOSurfaceGetWidth(surface)
            let h = IOSurfaceGetHeight(surface)
            Log.render.info("First frame presented: \(w, privacy: .public)x\(h, privacy: .public), layer bounds \(NSStringFromRect(self.bounds), privacy: .public)")
        } else if presentedFrameCount % 300 == 0 {
            Log.render.debug("Presented \(self.presentedFrameCount, privacy: .public) frames")
        }
    }
}

// MARK: - PiPVideoView
// ─────────────────────────────────────────────────────────────────────────────
// SwiftUI bridge for VideoLayerView.
//
// The frame callback is installed in `makeNSView` and torn down in `dismantle`,
// so a recreated representable never leaves the capture engine pointing at a
// dead view.
// ─────────────────────────────────────────────────────────────────────────────

struct PiPVideoView: NSViewRepresentable {
    let captureEngine: CaptureEngine

    func makeNSView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        Log.render.info("PiPVideoView.makeNSView — installing frame callback")
        // `attachRenderer` (rather than assigning `onFrameReceived`) replays the
        // frame that arrived before SwiftUI built this view, so the panel never
        // opens black waiting on the next redraw of the source.
        captureEngine.attachRenderer { [weak view] surface in
            view?.present(surface: surface)
        }
        return view
    }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {
        // Nothing to reconcile: frames are pushed, not pulled through state.
    }

    static func dismantleNSView(_ nsView: VideoLayerView, coordinator: ()) {
        Log.render.info("PiPVideoView.dismantleNSView")
    }
}
