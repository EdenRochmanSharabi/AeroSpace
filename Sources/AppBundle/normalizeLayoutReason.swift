@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    refreshNativeTabDetection()
    let savedPositions = demoteInactiveTabs()
    try await promoteActiveWindows(savedPositions: savedPositions)
}

/// Saved position of a demoted tab, keyed by app PID.
private struct SavedTabPosition {
    let parent: NonLeafTreeNodeObject
    let index: Int
}

/// Demote tiled windows that have become inactive native tabs to popup container.
/// Returns a map of app PID → position where the demoted tab was, so the newly
/// active tab can be inserted at the same position (preserving layout order).
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
private func demoteInactiveTabs() -> [Int32: SavedTabPosition] {
    var savedPositions: [Int32: SavedTabPosition] = [:]
    for workspace in Workspace.all {
        for window in Array(workspace.allLeafWindowsRecursive) {
            guard let macWindow = window as? MacWindow else { continue }
            if isLikelyNativeTab(windowId: macWindow.windowId, appPid: macWindow.macApp.pid, appWindowCount: windowCountForApp(pid: macWindow.macApp.pid)) {
                // Save position before demoting
                if let parent = macWindow.parent as? NonLeafTreeNodeObject, let index = macWindow.ownIndex {
                    savedPositions[macWindow.macApp.pid] = SavedTabPosition(parent: parent, index: index)
                }
                macWindow.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
    }
    return savedPositions
}

/// Promote popup windows that are actually real windows (or newly active tabs).
/// If a saved position exists for the app, insert the promoted window there.
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
private func promoteActiveWindows(savedPositions: [Int32: SavedTabPosition]) async throws {
    for node in Array(macosPopupWindowsContainer.children) {
        guard let popup = node as? MacWindow else { continue }
        // Don't promote scratchpad windows
        if scratchpadWindowIds.contains(popup.windowId) { continue }
        // Don't promote inactive native tabs
        if isLikelyNativeTab(windowId: popup.windowId, appPid: popup.macApp.pid, appWindowCount: windowCountForApp(pid: popup.macApp.pid)) { continue }

        // Check if there's a saved position from a demoted tab of the same app
        if let saved = savedPositions[popup.macApp.pid] {
            popup.bind(to: saved.parent, adaptiveWeight: WEIGHT_AUTO, index: saved.index)
            continue
        }

        // No saved position — promote normally (new window, not a tab swap)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel) {
            try await popup.relayoutWindow(on: focus.workspace)
            try await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(window: Window, prevParentKind: NonLeafTreeNodeKind, workspace: Workspace) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace)
    }
}
