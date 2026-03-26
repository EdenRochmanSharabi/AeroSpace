@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await handleNativeTabsAndPopups()
    // CG window list may lag behind AX events on tab switches.
    // Only do a second pass if there are popup windows that might be pending promotion.
    if !macosPopupWindowsContainer.children.isEmpty {
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        try await handleNativeTabsAndPopups()
    }
}

@MainActor private var nativeTabRecheckTask: Task<(), any Error>? = nil

@MainActor
private func scheduleNativeTabRecheck() {
    nativeTabRecheckTask?.cancel()
    nativeTabRecheckTask = Task { @MainActor in
        try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        try Task.checkCancellation()
        try await handleNativeTabsAndPopups()
    }
}

/// Handle native tab detection and popup validation in a single pass.
/// When a tab switch happens, swap the inactive tab with the active one in-place
/// to preserve window positions in the tiling tree.
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
private func handleNativeTabsAndPopups() async throws {
    // Refresh CG cache ONCE for consistent tab detection throughout this function
    refreshNativeTabDetection()

    // Phase 1: Find popup windows that should be promoted (newly active tabs or real windows)
    // Use Array() snapshot to avoid mutation during iteration
    for node in Array(macosPopupWindowsContainer.children) {
        guard let popup = node as? MacWindow else { continue }

        // Skip scratchpad windows
        if scratchpadWindowIds.contains(popup.windowId) { continue }

        // Skip windows that are still inactive tabs
        if isLikelyNativeTab(windowId: popup.windowId, appPid: popup.macApp.pid) { continue }

        // This popup should be promoted. Check if it's replacing a tiled inactive tab from the same app.
        var swapped = false
        for workspace in Workspace.all {
            for window in workspace.allLeafWindowsRecursive {
                guard let tiledWindow = window as? MacWindow else { continue }
                if tiledWindow.macApp.pid == popup.macApp.pid &&
                   isLikelyNativeTab(windowId: tiledWindow.windowId, appPid: tiledWindow.macApp.pid) {
                    // Swap: put popup in the tiled window's position, demote tiled window
                    let parent = tiledWindow.parent
                    let index = tiledWindow.ownIndex
                    tiledWindow.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                    if let parent, let index {
                        popup.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
                    }
                    swapped = true
                    break
                }
            }
            if swapped { break }
        }

        if !swapped {
            let windowLevel = getWindowLevel(for: popup.windowId)
            if try await popup.isWindowHeuristic(windowLevel) {
                try await popup.relayoutWindow(on: focus.workspace)
                try await tryOnWindowDetected(popup)
            }
        }
    }

    // Phase 2: Demote any remaining tiled windows that are now inactive tabs
    for workspace in Workspace.all {
        for window in Array(workspace.allLeafWindowsRecursive) {
            guard let macWindow = window as? MacWindow else { continue }
            if isLikelyNativeTab(windowId: macWindow.windowId, appPid: macWindow.macApp.pid) {
                macWindow.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
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
