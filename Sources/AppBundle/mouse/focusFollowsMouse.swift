import AppKit
import Common

/// Focus follows mouse: automatically focus the window under the cursor.
/// https://github.com/nikitabobko/AeroSpace/issues/12

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

        if let window = findWindowAtPoint(mouse, in: workspace) {
            if focus.windowOrNil?.windowId != window.windowId {
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await runLightSession(.focusFollowsMouse, token) {
                    _ = window.focusWindow()
                    window.nativeFocus()
                }
            }
        }
    }
}

/// Find the topmost window at the given point.
/// Uses CGWindowListCopyWindowInfo which returns windows in z-order (front-to-back),
/// so floating windows on top are found first.
@MainActor
private func findWindowAtPoint(_ point: CGPoint, in workspace: Workspace) -> Window? {
    // Get all on-screen windows in z-order from CG
    let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
    guard let cgWindows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else {
        return nil
    }

    // Build a set of window IDs in the workspace for fast lookup
    let workspaceWindowIds = Set(workspace.allLeafWindowsRecursive.map { $0.windowId })

    // Iterate CG windows in z-order (front-to-back)
    for cgWindow in cgWindows {
        guard let wid = cgWindow[kCGWindowNumber as String] as? Int else { continue }
        let windowId = UInt32(wid)

        // Only consider windows that AeroSpace manages in this workspace
        guard workspaceWindowIds.contains(windowId) else { continue }
        guard let window = MacWindow.allWindowsMap[windowId] else { continue }

        // Check if point is within this window's bounds
        guard let boundsDict = cgWindow[kCGWindowBounds as String] else { continue }
        var cgRect = CGRect.zero
        CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &cgRect)
        let rect = cgRect.monitorFrameNormalized()

        if rect.contains(point) {
            return window
        }
    }

    return nil
}
