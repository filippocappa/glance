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

// MARK: - Drawing

func drawIcon(size: CGFloat, into context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }

    // Work in a normalised 1024x1024 space so every constant below is
    // resolution-independent; the transform scales it to the requested size.
    let s = size / 1024.0
    context.scaleBy(x: s, y: s)

    let tile = 1024 * canvasRatio
    let inset = (1024 - tile) / 2
    let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)
    let radius = tile * cornerRatio

    // ── Tile: dark vertical gradient ────────────────────────────────────
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.16, 0.17, 0.21, 1.0])!,
            CGColor(colorSpace: space, components: [0.07, 0.07, 0.09, 1.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.midX, y: tileRect.minY),
        options: []
    )

    // A soft top highlight keeps the tile from looking flat at large sizes.
    let highlight = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [1, 1, 1, 0.10])!,
            CGColor(colorSpace: space, components: [1, 1, 1, 0.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        highlight,
        start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
        end: CGPoint(x: tileRect.midX, y: tileRect.midY),
        options: []
    )
    context.restoreGState()

    // Hairline rim, so the tile keeps an edge against a dark wallpaper.
    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.14])!)
    context.setLineWidth(1024 * 0.004)
    context.strokePath()
    context.restoreGState()

    // ── Screen outline ──────────────────────────────────────────────────
    let screenWidth = tile * 0.60
    let screenHeight = screenWidth * 0.66
    let screenRect = CGRect(
        x: tileRect.midX - screenWidth / 2,
        y: tileRect.midY - screenHeight / 2 + tile * 0.045,
        width: screenWidth,
        height: screenHeight
    )
    let screenRadius = screenWidth * 0.10
    let stroke = tile * 0.052

    context.saveGState()
    context.addPath(CGPath(
        roundedRect: screenRect.insetBy(dx: stroke / 2, dy: stroke / 2),
        cornerWidth: screenRadius,
        cornerHeight: screenRadius,
        transform: nil
    ))
    context.setStrokeColor(CGColor(colorSpace: space, components: [0.93, 0.94, 0.97, 1.0])!)
    context.setLineWidth(stroke)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    // ── Picture-in-picture inset ────────────────────────────────────────
    // Overlaps the screen's lower-right corner and is knocked out of the
    // outline first, so the two shapes read as separate planes.
    let pipWidth = screenWidth * 0.46
    let pipHeight = pipWidth * 0.66
    let pipRect = CGRect(
        x: screenRect.maxX - pipWidth * 0.72,
        y: screenRect.minY - pipHeight * 0.30,
        width: pipWidth,
        height: pipHeight
    )
    let pipRadius = pipWidth * 0.20

    // Knockout gap: redraw the tile gradient through a slightly larger
    // rounded rect so the outline appears to pass behind the inset.
    let gap = stroke * 0.9
    context.saveGState()
    context.addPath(CGPath(
        roundedRect: pipRect.insetBy(dx: -gap, dy: -gap),
        cornerWidth: pipRadius + gap,
        cornerHeight: pipRadius + gap,
        transform: nil
    ))
    context.clip()
    context.setFillColor(CGColor(colorSpace: space, components: [0.10, 0.10, 0.13, 1.0])!)
    context.fill(tileRect)
    context.restoreGState()

    // The inset itself, in the app's accent blue.
    context.saveGState()
    context.addPath(CGPath(
        roundedRect: pipRect,
        cornerWidth: pipRadius,
        cornerHeight: pipRadius,
        transform: nil
    ))
    let accent = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(colorSpace: space, components: [0.36, 0.68, 1.00, 1.0])!,
            CGColor(colorSpace: space, components: [0.16, 0.44, 0.95, 1.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.clip()
    context.drawLinearGradient(
        accent,
        start: CGPoint(x: pipRect.minX, y: pipRect.maxY),
        end: CGPoint(x: pipRect.maxX, y: pipRect.minY),
        options: []
    )
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
