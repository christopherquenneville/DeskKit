import AppKit
import os

let appLog = Logger(subsystem: "tech.quenneville.DeskKit", category: "app")

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// The visible frame without the menu bar, even where AppKit leaves it in: macOS can show a menu
    /// bar on a display whose visibleFrame doesn't account for it (zoomed windows still stop below it).
    /// Asks the window server, so call it when screens change rather than all the time.
    var usableFrame: NSRect {
        var frame = visibleFrame
        let top = self.frame.maxY - menuBarHeight
        if frame.maxY > top { frame.size.height = max(0, top - frame.minY) }
        return frame
    }

    /// The height of the menu bar window along this display's top edge, or 0 when there is none.
    var menuBarHeight: CGFloat {
        let display = self.frame.inCGCoordinates
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        for window in windows where (window[kCGWindowLayer as String] as? NSNumber)?.intValue == level {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  abs(rect.minY - display.minY) < 1, abs(rect.minX - display.minX) < 1, rect.width >= display.width - 1,
                  rect.height < 100 else { continue }
            return rect.height
        }
        return 0
    }
}

extension NSRect {
    /// This rect in CoreGraphics' global coordinates: origin at the top left of the main display, y down.
    var inCGCoordinates: CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: mainHeight - maxY, width: width, height: height)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Moves `value` toward `target` by at most `step`.
func approach(_ value: CGFloat, _ target: CGFloat, _ step: CGFloat) -> CGFloat {
    value < target ? min(target, value + step) : max(target, value - step)
}

func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

/// A file URL's path without a trailing slash, for comparing app locations.
/// (Purely textual: standardizedFileURL would touch the disk on every comparison.)
func normalizedPath(_ url: URL) -> String {
    var path = url.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
}
