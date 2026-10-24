import AppKit
import ScreenCaptureKit

/// Window thumbnails for the picker. They need Screen & System Audio Recording permission; without
/// it the picker shows the app's icon instead.
@MainActor
enum WindowPreviews {
    /// Captures each window at no more than `size` points (times `scale` pixels), handing images back
    /// on the main actor as they arrive.
    static func capture(_ ids: [CGWindowID], fitting size: CGSize, scale: CGFloat,
                        each: @escaping @MainActor (CGWindowID, CGImage) -> Void) {
        guard !ids.isEmpty, Permissions.screenRecording else { return }
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

    /// The largest size with the same shape as `content` that fits in `box`.
    static func fit(_ content: CGSize, into box: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0 else { return box }
        let scale = min(box.width / content.width, box.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}
