import AppKit
import CoreGraphics
import ImageIO
import Foundation

func stripAlpha(from fileURL: URL) -> Bool {
    guard let image = NSImage(contentsOf: fileURL),
          let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let cgImage = bitmap.cgImage else {
        print("❌ Failed to load \(fileURL.lastPathComponent)")
        return false
    }

    let width = cgImage.width
    let height = cgImage.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Create a 24-bit/32-bit RGB context WITHOUT alpha (noneSkipLast = RGBX, fully opaque)
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        print("❌ Failed to create context for \(fileURL.lastPathComponent)")
        return false
    }

    // Fill background solid black first just in case
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Draw the image
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let outputCGImage = context.makeImage() else {
        print("❌ Failed to create output CGImage for \(fileURL.lastPathComponent)")
        return false
    }

    guard let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) else {
        print("❌ Failed to create destination for \(fileURL.lastPathComponent)")
        return false
    }

    CGImageDestinationAddImage(dest, outputCGImage, [
        kCGImagePropertyHasAlpha: false
    ] as CFDictionary)

    let success = CGImageDestinationFinalize(dest)
    if success {
        print("✅ Alpha removed: \(fileURL.path)")
    } else {
        print("❌ Failed to finalize: \(fileURL.path)")
    }
    return success
}

let folders = [
    "assets/appstore/ipad_2048x2732",
    "assets/appstore/ipad_2064x2752",
    "assets/appstore/iphone_1284x2778",
    "assets/appstore/iphone_1242x2688"
]

let fm = FileManager.default
for folder in folders {
    let dirURL = URL(fileURLWithPath: folder)
    guard let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else {
        continue
    }
    for file in files where file.pathExtension.lowercased() == "png" {
        _ = stripAlpha(from: file)
    }
}
print("Done! All App Store images have had alpha channels stripped.")
