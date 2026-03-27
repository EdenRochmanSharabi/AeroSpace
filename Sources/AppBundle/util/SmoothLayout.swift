import Foundation

/// Private SkyLight API bindings for smooth (flicker-free) window layout.
/// These APIs pause and resume screen rendering, allowing multiple window
/// moves to happen atomically without visible intermediate frames.
///
/// Used by yabai and Rectangle for the same purpose.
/// May break in future macOS updates — controlled by config option.
enum SmoothLayout {
    nonisolated(unsafe) private static var connectionId: Int32 = {
        guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return 0
        }
        guard let sym = dlsym(skylight, "SLSMainConnectionID") else { return 0 }
        typealias Fn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn()
    }()

    nonisolated(unsafe) private static var disableUpdateFn: (@convention(c) (Int32) -> Int32)? = {
        guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return nil
        }
        guard let sym = dlsym(skylight, "SLSDisableUpdate") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Int32).self)
    }()

    nonisolated(unsafe) private static var reenableUpdateFn: (@convention(c) (Int32) -> Int32)? = {
        guard let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return nil
        }
        guard let sym = dlsym(skylight, "SLSReenableUpdate") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Int32).self)
    }()

    static var isAvailable: Bool {
        connectionId != 0 && disableUpdateFn != nil && reenableUpdateFn != nil
    }

    /// Set at startup or config reload from MainActor. Read from any thread.
    nonisolated(unsafe) static var enabled: Bool = false

    /// Pause screen rendering. Call before batch window moves.
    static func disableUpdate() {
        guard isAvailable else { return }
        _ = disableUpdateFn?(connectionId)
    }

    /// Resume screen rendering. Call after all windows are in final positions.
    static func reenableUpdate() {
        guard isAvailable else { return }
        _ = reenableUpdateFn?(connectionId)
    }
}
