@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    cleanupStaleTabIds()
    refreshNativeTabDetection()
    demoteInactiveTabs()
    handleNativeTabSwitch()
    rescueLostWindows()
    try await validatePopups()
}

/// Remove stale entries from nativeTabWindowIds.
/// If a window is the only one from its app in allWindowsMap, it's not a tab anymore.
@MainActor
private func cleanupStaleTabIds() {
    // Remove IDs for windows that no longer exist
    nativeTabWindowIds = nativeTabWindowIds.filter { MacWindow.allWindowsMap[$0] != nil }

    // If an app only has 1 window left, it can't be a tab
    for windowId in Array(nativeTabWindowIds) {
        guard let window = MacWindow.allWindowsMap[windowId] else { continue }
        if windowCountForApp(pid: window.macApp.pid) <= 1 {
            nativeTabWindowIds.remove(windowId)
        }
    }
}

/// Safety net: if a window is on-screen (CG) but not in any workspace or popup, re-add it.
@MainActor
private func rescueLostWindows() {
    refreshNativeTabDetection()
    for window in MacWindow.allWindows {
        let hasParent = window.parent != nil
        if !hasParent && isWindowOnScreen(window.windowId) {
            // Window is lost — re-tile it
            window.bindAsFloatingWindow(to: focus.workspace)
            nativeTabWindowIds.remove(window.windowId)
        }
    }
}

/// Demote tiled windows that are no longer on-screen but their app has an on-screen window.
/// These are background native tabs that should not be tiled.
@MainActor
private func demoteInactiveTabs() {
    for workspace in Workspace.all {
        // Count tiled windows per app in this workspace BEFORE demoting
        var tiledCountPerApp: [Int32: Int] = [:]
        for window in workspace.allLeafWindowsRecursive {
            guard let macWindow = window as? MacWindow else { continue }
            tiledCountPerApp[macWindow.macApp.pid, default: 0] += 1
        }

        for window in Array(workspace.allLeafWindowsRecursive) {
            guard let macWindow = window as? MacWindow else { continue }
            // NEVER demote a window that is on-screen
            if isWindowOnScreen(macWindow.windowId) { continue }
            // NEVER demote if it's the only tiled window for this app
            if (tiledCountPerApp[macWindow.macApp.pid] ?? 0) <= 1 { continue }
            // Only demote if the app has another window that IS on-screen
            let appHasOnScreenWindow = MacWindow.allWindows.contains {
                $0.macApp.pid == macWindow.macApp.pid &&
                $0.windowId != macWindow.windowId &&
                isWindowOnScreen($0.windowId)
            }
            if appHasOnScreenWindow {
                nativeTabWindowIds.insert(macWindow.windowId)
                tiledCountPerApp[macWindow.macApp.pid, default: 0] -= 1
                macWindow.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
    }
}

/// Handle native tab switches by detecting when the focused window is a known tab in popup.
/// Swap it atomically with the currently tiled tab from the same app — no CG queries needed.
/// https://github.com/nikitabobko/AeroSpace/issues/68
@MainActor
private func handleNativeTabSwitch() {
    guard let focusedWindow = focus.windowOrNil as? MacWindow else { return }

    // Is the focused window a known tab sitting in the popup container?
    guard nativeTabWindowIds.contains(focusedWindow.windowId) else { return }
    guard let parentCases = focusedWindow.parent?.cases else { return }
    switch parentCases {
        case .macosPopupWindowsContainer: break // It's in popup — proceed with swap
        default: return // Already tiled or somewhere else — nothing to do
    }

    // Find the currently tiled tab from the same app to swap with
    for workspace in Workspace.all {
        for window in Array(workspace.allLeafWindowsRecursive) {
            guard let tiledTab = window as? MacWindow else { continue }
            if tiledTab.macApp.pid == focusedWindow.macApp.pid &&
               nativeTabWindowIds.contains(tiledTab.windowId) {
                // Atomic swap: save position, demote old, promote new at same position
                let parent = tiledTab.parent
                let index = tiledTab.ownIndex
                tiledTab.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                if let parent, let index {
                    focusedWindow.bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
                }
                return
            }
        }
    }

    // No tiled tab from same app found (e.g. all tabs were closed except this one).
    // Promote normally.
    focusedWindow.bindAsFloatingWindow(to: focus.workspace)
}

/// Promote popup windows that are real windows (not tabs, not scratchpad).
@MainActor
private func validatePopups() async throws {
    for node in Array(macosPopupWindowsContainer.children) {
        guard let popup = node as? MacWindow else { continue }
        if scratchpadWindowIds.contains(popup.windowId) { continue }
        if nativeTabWindowIds.contains(popup.windowId) { continue }
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
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer:
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await window.relayoutWindow(on: workspace)
    }
}
