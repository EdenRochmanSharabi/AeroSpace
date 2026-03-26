import AppKit
import Common

struct StickyCommand: Command {
    let args: StickyCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        guard window.isFloating else {
            return io.err("Only floating windows can be made sticky. Use 'layout floating' first")
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isSticky
        }
        window.isSticky = newState
        return true
    }
}
