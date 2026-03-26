import CoreGraphics
import Foundation

@MainActor
private var levelCache: [UInt32: MacOsWindowLevel] = [:]

@MainActor
private struct CgWindowInfo {
    let level: MacOsWindowLevel
    let bounds: CGRect
    let ownerPid: pid_t
}

@MainActor
private var cgWindowInfoCache: [UInt32: CgWindowInfo] = [:]

@MainActor
private func refreshCgWindowInfoCache() {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return }

    var levels: [UInt32: MacOsWindowLevel] = [:]
    var infos: [UInt32: CgWindowInfo] = [:]

    for elem in cfArray {
        let dict = elem as NSDictionary

        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value

        guard let _windowLayer = dict[kCGWindowLayer] else { continue }
        let windowLayer = ((_windowLayer as! CFNumber) as NSNumber).intValue

        guard let _pid = dict[kCGWindowOwnerPID] else { continue }
        let pid = ((_pid as! CFNumber) as NSNumber).int32Value

        var bounds = CGRect.zero
        if let boundsDict = dict[kCGWindowBounds] {
            CGRectMakeWithDictionaryRepresentation(boundsDict as! CFDictionary, &bounds)
        }

        let level = MacOsWindowLevel.new(windowLevel: windowLayer)
        levels[windowId] = level
        infos[windowId] = CgWindowInfo(level: level, bounds: bounds, ownerPid: pid)
    }
    levelCache = levels
    cgWindowInfoCache = infos
}

@MainActor
func getWindowLevel(for windowId: UInt32) -> MacOsWindowLevel? {
    if let existing = levelCache[windowId] { return existing }
    refreshCgWindowInfoCache()
    return levelCache[windowId]
}

/// Refresh the CG cache once, then use isLikelyNativeTab for consistent results within a single pass.
@MainActor
func refreshNativeTabDetection() {
    refreshCgWindowInfoCache()
}

/// Check if a window is currently on-screen according to CG cache.
@MainActor
func isWindowOnScreen(_ windowId: UInt32) -> Bool {
    cgWindowInfoCache[windowId] != nil
}

/// Set of window IDs that were detected as native tabs at registration time.
/// Once a window is identified as a tab, it stays a tab until it's garbage collected.
@MainActor var nativeTabWindowIds: Set<UInt32> = []

/// Count how many windows AeroSpace knows about for a given app PID.
/// Includes tiled, floating, and popup windows.
@MainActor
func windowCountForApp(pid: pid_t) -> Int {
    MacWindow.allWindows.count(where: { $0.macApp.pid == pid })
}

/// Detect macOS native tabs: the AX API reports tabs as separate windows, but only the active
/// tab appears in CGWindowListCopyWindowInfo(.optionOnScreenOnly). If a window is NOT on screen
/// but another window from the same app IS on screen, it's likely an inactive native tab.
/// https://github.com/nikitabobko/AeroSpace/issues/68
///
/// Key safety check: only detect tabs when the app has MORE AeroSpace windows than CG on-screen
/// windows. This prevents false positives with separate windows of the same app (e.g. 2 Finder
/// windows at different positions) where one is temporarily off-screen due to CG lag.
@MainActor
func isLikelyNativeTab(windowId: UInt32, appPid: pid_t, appWindowCount: Int) -> Bool {
    // If the app only has 1 window known to AeroSpace, it can't be a tab
    if appWindowCount <= 1 { return false }

    // If this window IS on screen, it's either a real window or the active tab — tile it normally.
    if cgWindowInfoCache[windowId] != nil { return false }

    // Count how many windows from this app CG reports as on-screen
    let cgOnScreenCount = cgWindowInfoCache.values.count(where: { $0.ownerPid == appPid && $0.level == .normalWindow })

    // If CG shows 0 on-screen windows for this app, it's likely a CG lag — don't mark as tab
    if cgOnScreenCount == 0 { return false }

    // If CG on-screen count >= total AeroSpace windows, all windows are real (no tabs)
    // This prevents false positives with separate windows (e.g. 2 Finder windows)
    if cgOnScreenCount >= appWindowCount { return false }

    // CG shows fewer on-screen windows than AeroSpace knows about → excess are tabs
    return true
}

enum MacOsWindowLevel: Sendable, Equatable {
    case normalWindow
    case alwaysOnTopWindow
    case unknown(windowLevel: Int)

    static func new(windowLevel: Int) -> MacOsWindowLevel {
        switch windowLevel {
            case 0: .normalWindow
            case 3: .alwaysOnTopWindow
            default: .unknown(windowLevel: windowLevel)
        }
    }

    static func fromJson(_ json: Json) -> MacOsWindowLevel? {
        switch json {
            case .string("normalWindow"): .normalWindow
            case .string("alwaysOnTopWindow"): .alwaysOnTopWindow
            case .int(let int): .new(windowLevel: Int(exactly: int).orDie())
            default: nil
        }
    }

    func toJson() -> Json {
        switch self {
            case .normalWindow: .string("normalWindow")
            case .alwaysOnTopWindow: .string("alwaysOnTopWindow")
            case .unknown(let layerNumber): .int(layerNumber)
        }
    }
}
