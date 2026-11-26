import AppKit
import ScreenCaptureKit

/// Window thumbnails for the picker. They need Screen & System Audio Recording permission; without
/// it the picker shows the app's icon instead.
@MainActor
enum WindowPreviews {
    /// Captures each window at no more than `size` points (times `scale` pixels), handing images back
    /// on the main actor as they arrive. ScreenCaptureKit only captures windows on the current Spaces,
    /// so those on other Spaces (a full-screen app's, say), `elsewhere`, come from the window server.
    static func capture(_ windows: [CGWindowID], elsewhere: Set<CGWindowID> = [], fitting size: CGSize, scale: CGFloat,
                        each: @escaping @MainActor (CGWindowID, CGImage) -> Void) {
        guard !windows.isEmpty, Permissions.screenRecording else { return }
        let ids = windows.filter { !elsewhere.contains($0) }
        if windows.contains(where: elsewhere.contains) {
            Task { @MainActor in
                for id in windows where elsewhere.contains(id) {
                    if let image = captureElsewhere(id, fitting: size, scale: scale) { each(id, image) }
                }
            }
        }
        guard !ids.isEmpty else { return }
        if #available(macOS 14, *) {
            Task { @MainActor in
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                    return
                }
                for id in ids {
                    guard let window = content.windows.first(where: { $0.windowID == id }) else { continue }
                    let fitted = fit(window.frame.size, into: size)
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(1, Int(fitted.width * scale))
                    configuration.height = max(1, Int(fitted.height * scale))
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                        each(id, image)
                    }
                }
            }
        } else {
            for id in ids {
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) {
                    each(id, image)
                }
            }
        }
    }

    /// A window's image from the window server's private capture call (the one AltTab uses), which also
    /// reaches windows on other Spaces; looked up at run time. Scaled down to fit `size` at `scale`.
    private static func captureElsewhere(_ id: CGWindowID, fitting size: CGSize, scale: CGFloat) -> CGImage? {
        guard let capture = captureWindowList, let connection = Spaces.connection else { return nil }
        var window = id
        // Ignoring the global clip shape (1 << 11), at one pixel per point (1 << 9).
        guard let images = capture(connection, &window, 1, 1 << 11 | 1 << 9)?.takeRetainedValue() as? [CGImage],
              let image = images.first else { return nil }
        return scaled(image, toFit: CGSize(width: size.width * scale, height: size.height * scale))
    }

    private typealias CaptureWindowList = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private static let captureWindowList: CaptureWindowList? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSHWCaptureWindowList") else { return nil }
        return unsafeBitCast(symbol, to: CaptureWindowList.self)
    }()

    /// `image` scaled down to fit `box` pixels, if it's bigger, so a large window's capture doesn't
    /// stay in memory at full size.
    private static func scaled(_ image: CGImage, toFit box: CGSize) -> CGImage {
        let fitted = fit(CGSize(width: image.width, height: image.height), into: box)
        let width = Int(fitted.width.rounded()), height = Int(fitted.height.rounded())
        guard width > 0, height > 0, width < image.width, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// The largest size with the same shape as `content` that fits in `box`.
    static func fit(_ content: CGSize, into box: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0 else { return box }
        let scale = min(box.width / content.width, box.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}
