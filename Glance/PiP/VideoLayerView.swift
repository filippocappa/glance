import AppKit
import QuartzCore
import Metal
import CoreImage
import SwiftUI

// MARK: - MetalVideoView
// ─────────────────────────────────────────────────────────────────────────────
// Renders captured CVPixelBuffer frames using CAMetalLayer and CIContext for
// hardware-accelerated GPU rendering. This bypasses SwiftUI state updates completely
// during the capture stream, preventing CPU-bound lag.
// ─────────────────────────────────────────────────────────────────────────────

class MetalVideoView: NSView {
    
    private var metalLayer: CAMetalLayer {
        return self.layer as! CAMetalLayer
    }
    
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMetal()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetal()
    }
    
    private func setupMetal() {
        self.wantsLayer = true
        
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            print("[MetalVideoView] Metal is not supported on this system")
            return
        }
        
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSColorSpace.sRGB.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
        ])
        
        let mLayer = CAMetalLayer()
        mLayer.device = device
        mLayer.pixelFormat = .bgra8Unorm
        mLayer.framebufferOnly = false
        mLayer.contentsGravity = .resizeAspect
        
        self.layer = mLayer
    }
    
    /// Renders a CVPixelBuffer frame directly to the GPU using Metal and CoreImage.
    func render(pixelBuffer: CVPixelBuffer) {
        guard self.device != nil,
              let commandQueue = commandQueue,
              let ciContext = ciContext,
              let drawable = metalLayer.nextDrawable() else {
            return
        }
        
        // Dynamically adjust drawable size to match the frame aspect ratio/resolution.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bufferSize = CGSize(width: width, height: height)
        
        if metalLayer.drawableSize != bufferSize {
            metalLayer.drawableSize = bufferSize
        }
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        let destination = CIRenderDestination(
            width: width,
            height: height,
            pixelFormat: metalLayer.pixelFormat,
            commandBuffer: commandBuffer
        ) { () -> MTLTexture in
            return drawable.texture
        }
        
        do {
            try ciContext.startTask(toRender: ciImage, to: destination)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch {
            print("[MetalVideoView] Error rendering to Metal drawable: \(error)")
        }
    }
}

// MARK: - PiPVideoView
// ─────────────────────────────────────────────────────────────────────────────
// A SwiftUI wrapper (NSViewRepresentable) for MetalVideoView.
// Allows us to insert the high-performance Metal-based renderer directly into
// SwiftUI views.
// ─────────────────────────────────────────────────────────────────────────────

struct PiPVideoView: NSViewRepresentable {
    let captureEngine: CaptureEngine
    
    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView()
        // Register the callback to update the view directly from the capture engine
        captureEngine.onFrameReceived = { [weak view] pixelBuffer in
            view?.render(pixelBuffer: pixelBuffer)
        }
        return view
    }
    
    func updateNSView(_ nsView: MetalVideoView, context: Context) {
        // No-op
    }
}
