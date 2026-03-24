//
//  DesignSystem.swift
//  PureStems
//
//  PureVibes design language components: WindowAccessor, VisualEffectView,
//  GlassButton, and NSImage.dominantColor().
//

import SwiftUI
import AppKit
import CoreImage

// MARK: - Blurred Image Cache

extension NSImage {
    private static let blurCache = NSCache<NSString, NSImage>()

    /// Returns a Gaussian-blurred copy of this image, cached by radius.
    func blurred(radius: CGFloat) -> NSImage? {
        let cacheKey = "\(ObjectIdentifier(self).hashValue)_\(radius)" as NSString
        if let cached = NSImage.blurCache.object(forKey: cacheKey) {
            return cached
        }

        guard let tiff = self.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }

        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)

        guard let outputImage = filter?.outputImage else { return nil }

        let ciContext = CIContext()
        // Use the original image extent to avoid blur edge expansion
        guard let cgImage = ciContext.createCGImage(outputImage, from: ciImage.extent) else { return nil }

        let result = NSImage(cgImage: cgImage, size: self.size)
        NSImage.blurCache.setObject(result, forKey: cacheKey)
        return result
    }
}

// MARK: - Window Accessor

/// Configures the hosting window for a transparent, immersive look.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = false
                window.isMovable = true
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Visual Effect View

/// NSVisualEffectView wrapper for behind-window vibrancy blur.
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Faint Grid Background

/// Shimmering dot grid with sine/cosine-modulated opacity for depth.
struct FaintGridBackground: View {
    var isProcessing: Bool = false
    var isAppActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: !isProcessing || reduceMotion || !isAppActive)) { timeline in
            Canvas { context, size in
                // Only advance time if processing to save energy
                let time = isProcessing ? timeline.date.timeIntervalSinceReferenceDate : 0
                
                let width = size.width
                let height = size.height
                let spacing: CGFloat = 25

                for x in stride(from: 0, to: width, by: spacing) {
                    for y in stride(from: 0, to: height, by: spacing) {
                        let rect = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                        
                        let baseOpacity = 0.1 + (sin(x * 0.01) * cos(y * 0.01) * 0.05)
                        var finalOpacity = baseOpacity
                        
                        if isProcessing {
                            // Create a diagonal rolling wave
                            let wave = sin((x + y) * 0.01 - time * 3.0)
                            if wave > 0.8 {
                                finalOpacity += 0.2 * wave // Boost opacity where the wave hits
                            }
                        }
                        
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(Color.white.opacity(finalOpacity))
                        )
                    }
                }
            }
        }
        .background(Color.black)
        .allowsHitTesting(false)
    }
}

// MARK: - Glass Button

/// Circular button with ultra-thin material, gradient stroke, and drop shadow.
struct GlassButton: View {
    let icon: String
    var size: CGFloat = 48
    var iconSize: CGFloat = 18
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.accentColor.opacity(0.7))
                .frame(width: size, height: size)
                .background(Material.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.6), .white.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Panel Modifier

/// Applies the glassmorphic card style used throughout PureVibes.
struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(Material.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.7),
                                .white.opacity(0.1),
                                .white.opacity(0.4)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 15, x: 0, y: 10)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Dominant Color

extension NSImage {
    /// Extracts the average color from a downsampled version of the image.
    func dominantColor() -> Color {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .black
        }

        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return .black }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        let pixelCount = CGFloat(width * height)

        for i in stride(from: 0, to: rawData.count, by: 4) {
            totalR += CGFloat(rawData[i])
            totalG += CGFloat(rawData[i + 1])
            totalB += CGFloat(rawData[i + 2])
        }

        return Color(
            red:   Double(totalR / pixelCount / 255.0),
            green: Double(totalG / pixelCount / 255.0),
            blue:  Double(totalB / pixelCount / 255.0)
        )
    }
}
