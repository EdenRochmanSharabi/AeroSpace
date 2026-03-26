import AppKit
import Common

@MainActor private var focusFollowsMouseTask: Task<(), any Error>? = nil

@MainActor
func handleFocusFollowsMouse() {
    guard config.focusFollowsMouse else { return }
    // Don't interfere while user is dragging/resizing
    if isLeftMouseButtonDown { return }

    // Debounce: cancel previous pending focus change
    focusFollowsMouseTask?.cancel()
    focusFollowsMouseTask = Task { @MainActor in
        try Task.checkCancellation()
        // 50ms debounce to avoid excessive focus changes
        try await Task.sleep(nanoseconds: 50_000_000)
        try Task.checkCancellation()

        let mouse = mouseLocation
        let targetMonitor = mouse.monitorApproximation
        let workspace = targetMonitor.activeWorkspace

        // Check tiling windows first (they don't overlap)
        if let window = findWindowAt(mouse, in: workspace) {
            if focus.windowOrNil?.windowId != window.windowId {
                _ = window.focusWindow()
                window.nativeFocus()
            }
        }
    }
}

@MainActor
private func findWindowAt(_ point: CGPoint, in workspace: Workspace) -> Window? {
    // Check floating windows first (they're on top)
    for child in workspace.children.reversed() {
        guard let window = child as? Window else { continue }
        guard let macWindow = window as? MacWindow else { continue }
        if macWindow.isHiddenInCorner { continue }
        // Use last known size for a quick bounds check
        // For floating windows, check if point is within their frame
        if let rect = lastKnownRect(for: macWindow), rect.contains(point) {
            return window
        }
    }
    // Check tiling windows
    for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
        guard let macWindow = window as? MacWindow else { continue }
        if macWindow.isHiddenInCorner { continue }
        if let rect = lastKnownRect(for: macWindow), rect.contains(point) {
            return window
        }
    }
    return nil
}

/// Get window rect from CG window list (fast, no AX call needed)
@MainActor
private func lastKnownRect(for window: MacWindow) -> Rect? {
    let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
    guard let list = CGWindowListCopyWindowInfo(options, CGWindowID(window.windowId)) as? [[String: Any]] else { return nil }
    // Get the specific window
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else { return nil }
    for w in cfArray {
        guard let wid = w["kCGWindowNumber"] as? Int, UInt32(wid) == window.windowId else { continue }
        guard let boundsDict = w["kCGWindowBounds"] else { continue }
        var cgRect = CGRect.zero
        CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &cgRect)
        return cgRect.monitorFrameNormalized()
    }
    return nil
}
