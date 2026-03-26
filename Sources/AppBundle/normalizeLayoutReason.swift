@MainActor
func normalizeLayoutReason() async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    handleNativeTabSwitch()
    try await validatePopups()
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
        case .workspace:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, forceTile: true)
        case .macosPopupWindowsContainer:
            try await window.relayoutWindow(on: workspace)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            try await window.relayoutWindow(on: workspace)
    }
}
