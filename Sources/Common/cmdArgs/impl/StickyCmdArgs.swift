public struct StickyCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .sticky,
        allowInConfig: true,
        help: sticky_help_generated,
        flags: [
            "--window-id": optionalWindowIdFlag(),
        ],
        posArgs: [ArgParser(\.toggle, parseStickyToggle)],
    )

    public var toggle: ToggleEnum = .toggle
}

private func parseStickyToggle(i: PosArgParserInput) -> ParsedCliArgs<ToggleEnum> {
    switch i.arg {
        case "on": .succ(.on, advanceBy: 1)
        case "off": .succ(.off, advanceBy: 1)
        default: .fail("Expected 'on' or 'off', got '\(i.arg)'", advanceBy: 1)
    }
}

func parseStickyCmdArgs(_ args: StrArrSlice) -> ParsedCmd<StickyCmdArgs> {
    parseSpecificCmdArgs(StickyCmdArgs(rawArgs: args), args)
}
