#!/usr/bin/env swift
//
// make_app_icon.swift — renders the OnDevice Max app mark.
//
// The mark is the app's own throughput trace: a stepped white line over a
// flat near-black ground. One shape, nothing else.

//
// It replaces a "MAX" wordmark set in SF Pro Black over a top-down gradient
// sheen. That mark predated the Instrument language and contradicted three of
// its rules at once — a gradient, a near-white that was not the UI's white,
// and a wordmark doing the work a glyph should do. A wordmark also says
// nothing about the product: every app could use one.
//
// A stepped line says "this thing measures something", reads at 40pt on a home
// screen, and is literally the same shape `InstrumentTrace` draws on the SYS
// tab — so the icon and the app's most distinctive screen share a mark.
//
// Kept in the repo so the icon is reproducible rather than a binary someone
// has to re-derive.
//
// Usage:  swift scripts/make_app_icon.swift
//
// Writes:
//   IOSLocalLLM/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   IOSLocalLLM/Assets.xcassets/AppIconPreview.imageset/AppIconPreview-256.png
//   IOSLocalLLM/Assets.xcassets/AppLogo.imageset/AppLogo.png

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette
//
// Exactly the app's dark appearance. The ground is #0A0B0D — the same value as
// `KoduTheme.dark.bg` and `LaunchBackground` — so icon, launch screen and first
// frame are one continuous surface. Flat: no gradient, because the design has
// no z-axis and a sheen is the clearest possible signal that a mark was drawn
// to look like a button.

let ground = CGColor(red: 0.039, green: 0.043, blue: 0.051, alpha: 1)   // #0A0B0D
let trace = CGColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)    // #FFFFFF — the live colour
// (No grid colour — see the Geometry section for why the gridlines were cut.)

let side: CGFloat = 1024

guard
    let ctx = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else {
    FileHandle.standardError.write(Data("could not create context\n".utf8))
    exit(1)
}

// MARK: - Ground

ctx.setFillColor(ground)
ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

// MARK: - Geometry
//
// iOS masks the icon to a squircle and the home screen crops harder than the
// 1024 master suggests, so the mark lives inside the middle ~62% horizontally.
// A trace that ran edge to edge would lose its first and last step to the mask.

let inset: CGFloat = side * 0.165
let plotW = side - inset * 2
// Wide and shallow. The first cut used a 0.34 plot height with a monotonic
// sample set, which made the mark read as a staircase rather than a readout —
// a trace is a horizontal thing that wobbles, not a diagonal that climbs.
let plotH = side * 0.26
let plotY = (side - plotH) / 2

// No gridlines. `InstrumentTrace` draws two on screen, and carrying them into
// the mark seemed like the consistent choice — but at icon scale they have no
// tick labels or axis to belong to, so they read as two stray hairlines
// escaping either side of the glyph rather than as a grid. The mark is one
// shape.

// MARK: - Trace
//
// Nine samples, normalised 0–1 bottom to top. Chosen for silhouette: the line
// must return to mid-height repeatedly so it reads as a signal oscillating
// about a baseline. An ascending set — which the first cut used — turns the
// same geometry into a staircase glyph, because every step goes the same way.
// One clear peak past centre gives it an asymmetric, memorable profile.

let samples: [CGFloat] = [0.34, 0.56, 0.22, 0.48, 0.78, 0.30, 0.96, 0.44, 0.62]
let step = plotW / CGFloat(samples.count - 1)

let path = CGMutablePath()
for (i, v) in samples.enumerated() {
    let x = inset + CGFloat(i) * step
    let y = plotY + plotH * v
    if i == 0 {
        path.move(to: CGPoint(x: x, y: y))
    } else {
        // Stepped, not interpolated — the same discrete-sample logic the live
        // trace uses. The right angles are most of the mark's character.
        let prevY = plotY + plotH * samples[i - 1]
        path.addLine(to: CGPoint(x: x, y: prevY))
        path.addLine(to: CGPoint(x: x, y: y))
    }
}

ctx.setStrokeColor(trace)
// 3.6% of the side ≈ 6.5px at the 180px home-screen render. The first cut ran
// 5.4%, which was heavy enough that adjacent steps visually merged into a solid mass.
ctx.setLineWidth(side * 0.036)
ctx.setLineJoin(.miter)
ctx.setLineCap(.butt)
ctx.addPath(path)
ctx.strokePath()

guard let master = ctx.makeImage() else {
    FileHandle.standardError.write(Data("could not render master\n".utf8))
    exit(1)
}

// MARK: - Output

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func writePNG(_ image: CGImage, size: CGFloat, to path: String) {
    var target = image
    if size != CGFloat(image.width) {
        guard
            let scaleCtx = CGContext(
                data: nil,
                width: Int(size),
                height: Int(size),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let resized = { () -> CGImage? in
                scaleCtx.interpolationQuality = .high
                scaleCtx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
                return scaleCtx.makeImage()
            }()
        else {
            FileHandle.standardError.write(Data("could not resample to \(size)\n".utf8))
            exit(1)
        }
        target = resized
    }

    let url = root.appendingPathComponent(path)
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not open \(path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, target, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("could not write \(path)\n".utf8))
        exit(1)
    }
    print("wrote \(path) @ \(Int(size))px")
}

writePNG(master, size: 1024, to: "IOSLocalLLM/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
writePNG(
    master, size: 256,
    to: "IOSLocalLLM/Assets.xcassets/AppIconPreview.imageset/AppIconPreview-256.png")
// Filename must stay `AppLogo.png` — that is what the imageset's Contents.json
// points at, and what `Image("AppLogo")` resolves to.
writePNG(master, size: 512, to: "IOSLocalLLM/Assets.xcassets/AppLogo.imageset/AppLogo.png")
