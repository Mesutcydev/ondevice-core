#!/usr/bin/env swift
//
// make_app_icon.swift — renders the OnDevice Max app mark.
//
// A monolithic MAX wordmark: SF Pro Display Black, set tight, optically
// centred on a near-black ground with one restrained top-down sheen. No
// illustration, no mascot, no glow — the mark has to survive being 40pt on a
// home screen, and a wordmark at that size only works if it is the only thing
// there.
//
// Kept in the repo so the icon is reproducible rather than a binary someone
// has to re-derive. Uses the real system face via CoreText, so the mark is
// typographically identical to the app's own UI.
//
// Usage:  swift scripts/make_app_icon.swift
//
// Writes:
//   IOSLocalLLM/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   IOSLocalLLM/Assets.xcassets/AppIconPreview.imageset/AppIconPreview-256.png
//   IOSLocalLLM/Assets.xcassets/AppLogo.imageset/AppLogo-512.png

import AppKit
import CoreText
import Foundation

// MARK: - Palette
//
// Tracks the app's onyx/OLED language: a near-black ground and the same
// off-white the UI uses for primary ink (#F5F6F8). Pure white is avoided —
// it glares against the ground at icon scale.

// The ground spans a deliberately narrow luminance range. A wide gradient
// reads as a 2010-era glossy button; this is just enough tilt to suggest a
// surface under raking light.
let groundTop = CGColor(red: 0.086, green: 0.086, blue: 0.098, alpha: 1)  // #161619
let groundBottom = CGColor(red: 0.027, green: 0.027, blue: 0.035, alpha: 1)  // #070709
let inkColor = CGColor(red: 0.961, green: 0.965, blue: 0.973, alpha: 1)  // #F5F6F8

let side: CGFloat = 1024

// MARK: - Context

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
    FileHandle.standardError.write(Data("could not create bitmap context\n".utf8))
    exit(1)
}

ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)
ctx.setShouldSmoothFonts(true)

// MARK: - Ground
//
// A shallow vertical gradient rather than a flat fill. At icon scale a flat
// black tile reads as a hole in the home screen; ~8% of luminance range is
// enough to make it read as a surface catching light.

let full = CGRect(x: 0, y: 0, width: side, height: side)
if let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [groundBottom, groundTop] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: side),
        options: []
    )
} else {
    ctx.setFillColor(groundTop)
    ctx.fill(full)
}

// MARK: - Wordmark

/// Builds a single path for `text` with per-glyph tracking applied manually.
/// CTLine would honour kerning but not let us close the letters up as tightly
/// as a wordmark wants, so glyphs are positioned by hand.
func wordmarkPath(_ text: String, font: CTFont, tracking: CGFloat) -> (CGPath, CGRect) {
    let combined = CGMutablePath()
    var glyphs: [CGGlyph] = []
    var chars = Array(text.utf16)
    glyphs = Array(repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)

    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)

    var penX: CGFloat = 0
    for (index, glyph) in glyphs.enumerated() {
        if let glyphPath = CTFontCreatePathForGlyph(font, glyph, nil) {
            combined.addPath(glyphPath, transform: CGAffineTransform(translationX: penX, y: 0))
        }
        penX += advances[index].width
        if index < glyphs.count - 1 { penX += tracking }
    }
    return (combined, combined.boundingBoxOfPath)
}

// SF Pro Display Black. `.black` is the heaviest system weight; at display
// sizes macOS resolves the system font to the Display optical variant, which
// is the one with tight enough sidebearings for a wordmark.
let font = CTFontCreateWithFontDescriptor(
    NSFont.systemFont(ofSize: 300, weight: .black).fontDescriptor as CTFontDescriptor,
    300,
    nil
)

// Negative tracking pulls MAX into a single mass. Too far and the A's apex
// collides with the M's leg; -18 at 300pt is the point just before that.
let (rawPath, rawBounds) = wordmarkPath("MAX", font: font, tracking: -18)

// The mark is sized against the tile's full width, not the squircle's. iOS
// masks the corners, but the horizontal centre line is uncut — a vertically
// centred wordmark can therefore run much wider than a corner-safe inset
// would allow. 78% leaves the letterforms breathing room at 40pt.
let targetWidth = side * 0.78
let scale = targetWidth / rawBounds.width

var transform = CGAffineTransform.identity
// Optical centring: translate the path's own bounding box to the origin,
// scale, then place it at the tile centre. Using the bounding box rather than
// the font's metrics ignores ascender/descender space MAX doesn't occupy, so
// the mark sits where the eye expects instead of sitting high.
transform = transform.translatedBy(x: side / 2, y: side / 2)
transform = transform.scaledBy(x: scale, y: scale)
transform = transform.translatedBy(x: -rawBounds.midX, y: -rawBounds.midY)

guard let markPath = rawPath.copy(using: &transform) else {
    FileHandle.standardError.write(Data("could not transform wordmark path\n".utf8))
    exit(1)
}

ctx.addPath(markPath)
ctx.setFillColor(inkColor)
ctx.fillPath()

// MARK: - Sheen
//
// One soft highlight across the top third, clipped to nothing else. This is
// the whole "material" budget for the mark — anything more and it starts
// looking like a 2010 skeuomorph.

if let sheen = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.035),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
) {
    ctx.saveGState()
    ctx.clip(to: full)
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: 0, y: side),
        end: CGPoint(x: 0, y: side * 0.58),
        options: []
    )
    ctx.restoreGState()
}

// MARK: - Output

guard let master = ctx.makeImage() else {
    FileHandle.standardError.write(Data("could not snapshot context\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// Downsamples `master` to `size` and writes a PNG. Rendering once at 1024 and
/// resampling keeps every derived asset pixel-identical to the master instead
/// of re-running the type layout at each size.
func writePNG(_ image: CGImage, size: CGFloat, to path: String) {
    let target: CGImage
    if size == side {
        target = image
    } else {
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

import ImageIO
import UniformTypeIdentifiers

writePNG(master, size: 1024, to: "IOSLocalLLM/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
writePNG(
    master, size: 256,
    to: "IOSLocalLLM/Assets.xcassets/AppIconPreview.imageset/AppIconPreview-256.png")
// Filename must stay `AppLogo.png` — that is what the imageset's Contents.json
// points at, and what `Image("AppLogo")` resolves to on the splash screen.
writePNG(master, size: 512, to: "IOSLocalLLM/Assets.xcassets/AppLogo.imageset/AppLogo.png")
