#!/usr/bin/env swift

// make-icon.swift
// Glance
//
// Renders the Glance app icon programmatically with Core Graphics — no design
// tool, no binary assets in the repo. Emits every size the macOS asset catalog
// wants, writes them into Glance/Assets.xcassets/AppIcon.appiconset (with a
// matching Contents.json), and also produces a standalone Glance.icns.
//
// Usage:  swift Tools/make-icon.swift
//
// Design: a dark "squircle" tile carrying a rounded screen outline with a
// filled picture-in-picture inset tucked into its lower-right corner — the
// literal shape of what the app does.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// Apple's macOS app-icon grid: the visible tile occupies 824 of the 1024pt
/// canvas, leaving room for the system-drawn shadow.
let canvasRatio: CGFloat = 824.0 / 1024.0

/// Continuous-corner radius as a fraction of the tile's width. macOS uses
/// ~22.37%, which is what makes the shape read as a squircle rather than a
/// plain rounded rectangle.
let cornerRatio: CGFloat = 0.2237

// MARK: - Palette
//
// Mirrors Glance/Utilities/Theme.swift. Kept as literals rather than imported
// so this script stays runnable standalone with `swift Tools/make-icon.swift`.

let accent  = (r: 0.059, g: 0.796, b: 0.961)   // #0FCBF5 electric cyan
let accentD = (r: 0.039, g: 0.529, b: 0.769)   // #0A87C4

// MARK: - Drawing

func drawIcon(size: CGFloat, into context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }

    // Work in a normalised 1024x1024 space so every constant below is
    // resolution-independent; the transform scales it to the requested size.
    let s = size / 1024.0
    context.scaleBy(x: s, y: s)

    let space = CGColorSpaceCreateDeviceRGB()
    func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }

    let tile = 1024 * canvasRatio
    let inset = (1024 - tile) / 2
    let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)
    let radius = tile * cornerRatio
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    // ── Graphite tile ───────────────────────────────────────────────────
    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let body = CGGradient(
        colorsSpace: space,
        colors: [rgba(0.22, 0.23, 0.26, 1), rgba(0.09, 0.09, 0.11, 1)] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        body,
        start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.midX, y: tileRect.minY),
        options: []
    )

    // Specular sweep across the upper third, as if lit from above-left.
    let specular = CGGradient(
        colorsSpace: space,
        colors: [rgba(1, 1, 1, 0.16), rgba(1, 1, 1, 0.02), rgba(1, 1, 1, 0)] as CFArray,
        locations: [0.0, 0.45, 1.0]
    )!
    context.drawLinearGradient(
        specular,
        start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.midX, y: tileRect.midY),
        options: []
    )

    // Accent bloom in the lower right, tying the tile to the palette.
    let bloom = CGGradient(
        colorsSpace: space,
        colors: [rgba(accent.r, accent.g, accent.b, 0.20), rgba(accent.r, accent.g, accent.b, 0)] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawRadialGradient(
        bloom,
        startCenter: CGPoint(x: tileRect.maxX - tile * 0.12, y: tileRect.minY + tile * 0.12),
        startRadius: 0,
        endCenter: CGPoint(x: tileRect.maxX - tile * 0.12, y: tileRect.minY + tile * 0.12),
        endRadius: tile * 0.62,
        options: []
    )
    context.restoreGState()

    // Rim light: brighter along the top edge, so the tile reads as a solid
    // object rather than a flat sticker.
    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(rgba(1, 1, 1, 0.18))
    context.setLineWidth(1024 * 0.0045)
    context.strokePath()
    context.restoreGState()

    // ── Two overlapping glass panels ────────────────────────────────────
    // Back panel: the "full screen". Front panel: the picture-in-picture,
    // tucked into its lower-right corner and tinted with the accent.

    let backW = tile * 0.62
    let backH = backW * 0.64
    let backRect = CGRect(
        x: tileRect.midX - backW / 2 - tile * 0.045,
        y: tileRect.midY - backH / 2 + tile * 0.070,
        width: backW,
        height: backH
    )
    let backRadius = backW * 0.11

    let frontW = backW * 0.52
    let frontH = frontW * 0.64
    let frontRect = CGRect(
        x: backRect.maxX - frontW * 0.55,
        y: backRect.minY - frontH * 0.42,
        width: frontW,
        height: frontH
    )
    let frontRadius = frontW * 0.17

    func panelPath(_ rect: CGRect, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // Back panel — frosted white glass.
    context.saveGState()
    context.addPath(panelPath(backRect, backRadius))
    context.clip()
    let backFill = CGGradient(
        colorsSpace: space,
        colors: [rgba(1, 1, 1, 0.20), rgba(1, 1, 1, 0.07)] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        backFill,
        start: CGPoint(x: backRect.minX, y: backRect.maxY),
        end: CGPoint(x: backRect.maxX, y: backRect.minY),
        options: []
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(panelPath(backRect, backRadius))
    context.setStrokeColor(rgba(1, 1, 1, 0.68))
    context.setLineWidth(tile * 0.017)
    context.strokePath()
    context.restoreGState()

    // Knockout so the front panel reads as floating in front of the back one.
    let gap = tile * 0.013
    context.saveGState()
    context.addPath(panelPath(frontRect.insetBy(dx: -gap, dy: -gap), frontRadius + gap))
    context.clip()
    context.setBlendMode(.clear)
    context.fill(tileRect)
    context.setBlendMode(.normal)
    // Repaint the tile beneath the knockout.
    context.addPath(panelPath(frontRect.insetBy(dx: -gap, dy: -gap), frontRadius + gap))
    context.clip()
    let under = CGGradient(
        colorsSpace: space,
        colors: [rgba(0.20, 0.21, 0.24, 1), rgba(0.12, 0.12, 0.14, 1)] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        under,
        start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.midX, y: tileRect.minY),
        options: []
    )
    context.restoreGState()

    // Front panel — accent glass.
    context.saveGState()
    context.addPath(panelPath(frontRect, frontRadius))
    context.clip()
    let frontFill = CGGradient(
        colorsSpace: space,
        colors: [
            rgba(accent.r, accent.g, accent.b, 0.95),
            rgba(accentD.r, accentD.g, accentD.b, 0.95)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        frontFill,
        start: CGPoint(x: frontRect.minX, y: frontRect.maxY),
        end: CGPoint(x: frontRect.maxX, y: frontRect.minY),
        options: []
    )
    // Glass highlight across the top half of the panel.
    context.saveGState()
    context.addPath(panelPath(
        CGRect(x: frontRect.minX, y: frontRect.midY, width: frontRect.width, height: frontRect.height / 2),
        frontRadius
    ))
    context.clip()
    context.setFillColor(rgba(1, 1, 1, 0.18))
    context.fill(frontRect)
    context.restoreGState()
    context.restoreGState()

    context.saveGState()
    context.addPath(panelPath(frontRect, frontRadius))
    context.setStrokeColor(rgba(1, 1, 1, 0.85))
    context.setLineWidth(tile * 0.011)
    context.strokePath()
    context.restoreGState()
}

// MARK: - Rasterisation

func renderPNG(size: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a \(size)x\(size) bitmap context")
    }

    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    drawIcon(size: CGFloat(size), into: context)

    guard let image = context.makeImage() else { fatalError("makeImage failed") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return data
}

// MARK: - Output

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = repoRoot.appendingPathComponent("Glance/Assets.xcassets/AppIcon.appiconset")
let buildDir = repoRoot.appendingPathComponent("Tools/.iconbuild")
let iconsetDir = buildDir.appendingPathComponent("Glance.iconset")

let fm = FileManager.default
try? fm.removeItem(at: buildDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(at: iconSet, withIntermediateDirectories: true)

/// (point size, scale) pairs required by a macOS asset catalog.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

var catalogEntries: [String] = []

for variant in variants {
    let pixels = variant.points * variant.scale
    let data = renderPNG(size: pixels)

    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let filename = "icon_\(variant.points)x\(variant.points)\(suffix).png"

    try data.write(to: iconSet.appendingPathComponent(filename))

    // `iconutil` insists on its own naming scheme.
    try data.write(to: iconsetDir.appendingPathComponent(
        "icon_\(variant.points)x\(variant.points)\(suffix).png"
    ))

    catalogEntries.append("""
        {
          "filename" : "\(filename)",
          "idiom" : "mac",
          "scale" : "\(variant.scale)x",
          "size" : "\(variant.points)x\(variant.points)"
        }
    """)

    print("rendered \(filename) (\(pixels)px)")
}

let contents = """
{
  "images" : [
\(catalogEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try contents.write(
    to: iconSet.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

// Standalone .icns, useful outside the asset catalog.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconsetDir.path,
    "-o", repoRoot.appendingPathComponent("Tools/Glance.icns").path
]
try iconutil.run()
iconutil.waitUntilExit()

try? fm.removeItem(at: buildDir)

print("wrote \(iconSet.path)")
print("wrote Tools/Glance.icns")
