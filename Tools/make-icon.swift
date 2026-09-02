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
//
// Rendering technique matches Hum's Tools/make-icon.swift so the two apps read
// as a family: the same 0.06 canvas inset, the same top-lit body gradient, an
// accent bloom behind the mark, a two-pass glyph stroke (a wide coloured glow
// under a crisp near-white line), and a specular rim at the same weight.
//
// Where Hum uses a disc, Glance uses a squircle — the continuous-curvature
// rounded rectangle macOS itself uses for app tiles.

/// macOS icons sit inset within their canvas rather than filling it.
let canvasInset: CGFloat = 0.06

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

    let inset = 1024 * canvasInset
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let radius = rect.width * cornerRatio
    let tile = CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    // ── Obsidian body, top-lit ──────────────────────────────────────────
    context.saveGState()
    context.addPath(tile)
    context.clip()

    let body = CGGradient(
        colorsSpace: space,
        colors: [rgba(0.16, 0.15, 0.17, 1), rgba(0.05, 0.05, 0.06, 1)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        body,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: 0, y: rect.minY),
        options: []
    )

    // Accent bloom behind the mark.
    let bloom = CGGradient(
        colorsSpace: space,
        colors: [
            rgba(accent.r, accent.g, accent.b, 0.22),
            rgba(accent.r, accent.g, accent.b, 0.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        bloom,
        startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.5,
        options: []
    )

    // ── The mark: two overlapping rounded rectangles ────────────────────
    // Stroked, not filled — the same treatment as Hum's waveform: a wide
    // accent glow pass beneath a crisp near-white one.

    let backW = rect.width * 0.60
    let backH = backW * 0.66
    let backRect = CGRect(
        x: rect.midX - backW / 2 - rect.width * 0.035,
        y: rect.midY - backH / 2 + rect.height * 0.055,
        width: backW,
        height: backH
    )

    let frontW = backW * 0.50
    let frontH = frontW * 0.66
    let frontRect = CGRect(
        x: backRect.maxX - frontW * 0.58,
        y: backRect.minY - frontH * 0.40,
        width: frontW,
        height: frontH
    )

    func panel(_ r: CGRect, _ corner: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    let backPath = panel(backRect, backW * 0.11)
    let frontPath = panel(frontRect, frontW * 0.19)

    // Seam: clear a band around the front panel so the back outline reads as
    // passing behind it, then repaint the body beneath.
    let crisp = max(s * 0.028, 1.0) / s          // widths are in the 1024 space
    let glow = max(s * 0.070, 1.8) / s
    let seam = glow * 1.1

    func strokeTwoPass(_ path: CGPath) {
        context.setLineJoin(.round)
        context.setLineCap(.round)

        context.addPath(path)
        context.setStrokeColor(rgba(accent.r, accent.g, accent.b, 0.65))
        context.setLineWidth(glow)
        context.strokePath()

        context.addPath(path)
        context.setStrokeColor(rgba(0.93, 0.98, 1.0, 1.0))
        context.setLineWidth(crisp)
        context.strokePath()
    }

    // Back panel first, then knock the seam out of it.
    strokeTwoPass(backPath)

    context.saveGState()
    context.addPath(panel(frontRect.insetBy(dx: -seam, dy: -seam), frontW * 0.19 + seam))
    context.clip()
    context.setBlendMode(.clear)
    context.fill(rect)
    context.setBlendMode(.normal)
    context.addPath(panel(frontRect.insetBy(dx: -seam, dy: -seam), frontW * 0.19 + seam))
    context.clip()
    context.drawLinearGradient(
        body,
        start: CGPoint(x: 0, y: rect.maxY),
        end: CGPoint(x: 0, y: rect.minY),
        options: []
    )
    context.drawRadialGradient(
        bloom,
        startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.5,
        options: []
    )
    context.restoreGState()

    // Front panel: a faint accent glass fill so it reads as the live picture,
    // then the same two-pass outline.
    context.saveGState()
    context.addPath(frontPath)
    context.clip()
    let glass = CGGradient(
        colorsSpace: space,
        colors: [
            rgba(accent.r, accent.g, accent.b, 0.34),
            rgba(accentD.r, accentD.g, accentD.b, 0.16)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        glass,
        start: CGPoint(x: frontRect.minX, y: frontRect.maxY),
        end: CGPoint(x: frontRect.maxX, y: frontRect.minY),
        options: []
    )
    context.restoreGState()

    strokeTwoPass(frontPath)
    context.restoreGState()

    // ── Specular rim, brightest at the top edge ─────────────────────────
    context.addPath(tile)
    context.setStrokeColor(rgba(1, 1, 1, 0.16))
    context.setLineWidth(max(s * 0.006, 0.75) / s)
    context.strokePath()
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
