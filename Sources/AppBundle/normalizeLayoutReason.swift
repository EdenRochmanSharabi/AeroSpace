/// Positions saved when tab windows are garbage collected (closed).
/// Used by validatePopups to place the next tab at the same position.
@MainActor var closedWindowPositions: [Int32: BindingData] = [:]

@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    let savedTabPositions = demoteInactiveTabs()
    // Merge: positions from demote + positions from garbage-collected windows
    var allSavedPositions = closedWindowPositions
    for (pid, data) in savedTabPositions { allSavedPositions[pid] = data }
    closedWindowPositions = [:] // Clear after use
    try await validatePopups(savedTabPositions: allSavedPositions)
}

/// Promote popup windows that are actually real windows (or newly active tabs).
/// If a saved position exists from a demoted tab of the same app, use it to preserve layout order.
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
private func validatePopups(savedTabPositions: [Int32: BindingData]) async throws {
    refreshNativeTabDetection()
    for node in Array(macosPopupWindowsContainer.children) {
        guard let popup = node as? MacWindow else { continue }
        // Don't promote scratchpad windows
        if scratchpadWindowIds.contains(popup.windowId) { continue }
        // Don't promote inactive native tabs
        if isLikelyNativeTab(windowId: popup.windowId, appPid: popup.macApp.pid) { continue }
        // This window is on-screen and should be promoted to tiling
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel) {
            if let saved = savedTabPositions[popup.macApp.pid], saved.parent.isBound {
                let idx = min(saved.index, saved.parent.children.count)
                popup.bind(to: saved.parent, adaptiveWeight: saved.adaptiveWeight, index: idx)
            } else {
                try await popup.relayoutWindow(on: focus.workspace)
            }
            try await tryOnWindowDetected(popup)
        }
    }
}

/// Demote tiled windows that have become inactive native tabs to popup container.
/// Returns saved positions keyed by app PID so validatePopups can reuse them.
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
private func demoteInactiveTabs() -> [Int32: BindingData] {
    refreshNativeTabDetection()
    var saved: [Int32: BindingData] = [:]
    for workspace in Workspace.all {
        for window in Array(workspace.allLeafWindowsRecursive) {
            guard let macWindow = window as? MacWindow else { continue }
            if isLikelyNativeTab(windowId: macWindow.windowId, appPid: macWindow.macApp.pid) {
                if let old = macWindow.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST),
                   old.parent is TilingContainer {
                    saved[macWindow.macApp.pid] = old
                }
            }
        }
    }
    return saved
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
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace)
    }
}
