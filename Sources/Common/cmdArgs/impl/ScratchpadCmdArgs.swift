public enum ScratchpadAction: String, CaseIterable, Equatable, Sendable {
    case show
    case move
}

private func parseScratchpadAction(i: PosArgParserInput) -> ParsedCliArgs<ScratchpadAction> {
    switch i.arg {
        case "show": .succ(.show, advanceBy: 1)
        case "move": .succ(.move, advanceBy: 1)
        default: .fail("Unknown scratchpad action '\(i.arg)'. Expected 'show' or 'move'", advanceBy: 1)
    }
}

public struct ScratchpadCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .scratchpad,
        allowInConfig: true,
        help: scratchpad_help_generated,
        flags: [
            "--window-id": optionalWindowIdFlag(),
        ],
        posArgs: [newMandatoryPosArgParser(\.action, parseScratchpadAction, placeholder: "(show|move)")],
    )

    public var action: Lateinit<ScratchpadAction> = .uninitialized
}

func parseScratchpadCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ScratchpadCmdArgs> {
    parseSpecificCmdArgs(ScratchpadCmdArgs(rawArgs: args), args)
}
