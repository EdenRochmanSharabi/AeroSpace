import AppKit
import Common

/// Global set of window IDs that are in the scratchpad
@MainActor var scratchpadWindowIds: Set<UInt32> = []

struct ScratchpadCommand: Command {
    let args: ScratchpadCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        switch args.action.val {
            case .move:
                return try await scratchpadMove(env, io)
            case .show:
                return try await scratchpadShow(env, io)
        }
    }

    /// Move the focused window to the scratchpad (hide it)
    @MainActor
    private func scratchpadMove(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        scratchpadWindowIds.insert(window.windowId)
        window.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        return true
    }

    /// Toggle scratchpad window visibility on the current workspace
    @MainActor
    private func scratchpadShow(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        // Clean up stale IDs (windows that no longer exist)
        scratchpadWindowIds = scratchpadWindowIds.filter { MacWindow.allWindowsMap[$0] != nil }

        if scratchpadWindowIds.isEmpty {
            return io.err("No windows in scratchpad")
        }

        let workspace = focus.workspace

        // Check if any scratchpad window is already visible (floating) on the focused workspace
        for windowId in scratchpadWindowIds {
            guard let window = MacWindow.allWindowsMap[windowId] else { continue }
            if window.nodeWorkspace == workspace && window.isFloating {
                // It's visible — hide it back to popup container
                window.bind(to: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                return true
            }
        }

        // No scratchpad window visible — show the first available one
        for windowId in scratchpadWindowIds {
            guard let window = MacWindow.allWindowsMap[windowId] else { continue }
            window.bindAsFloatingWindow(to: workspace)
            window.nativeFocus()
            return true
        }

        return io.err("No windows in scratchpad")
    }
}
