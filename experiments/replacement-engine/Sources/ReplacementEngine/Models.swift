import ApplicationServices
import Darwin
import Foundation

enum ReplacementOutcome: String, Codable {
    case verifiedReplaced = "verified_replaced"
    case replacementDispatchedUnverified = "replacement_dispatched_unverified"
    case notReplaced = "not_replaced"
    case error
}

enum Strategy: String, Codable, CaseIterable {
    case axSelectedText = "ax_selected_text"
    case axValueRange = "ax_value_selected_range"
    case paste = "clipboard_cmd_v"
    case pasteMatchStyle = "paste_match_style"
    case unicodeInjection = "unicode_injection"
    case chunkedInjection = "chunked_injection"
}

enum AttemptOutcome: String, Codable {
    case verified
    case noOp = "no_op"
    case unavailable
    case skipped
    case dispatchedUnverified = "dispatched_unverified"
    case error
}

enum RunMode: String { case normal, single, from }

struct Options {
    var delayMilliseconds = 500
    var verificationTimeoutMilliseconds = 350
    var pollIntervalMilliseconds = 20
    var pasteHoldMilliseconds = 150
    var chunkSize = 16
    var chunkDelayMilliseconds = 8
    var mode: RunMode = .normal
    var strategy: Strategy?
    var controlledFixture = false
    var logPath = "~/Library/Logs/hir-249-replacement-engine.jsonl"

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func requireValue() throws -> String {
                guard index + 1 < arguments.count else { throw EngineError.invalidArgument("missing value for \(argument)") }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--delay-ms": options.delayMilliseconds = try positiveInt(try requireValue(), name: argument, allowZero: true)
            case "--verify-timeout-ms": options.verificationTimeoutMilliseconds = try positiveInt(try requireValue(), name: argument, allowZero: false)
            case "--poll-ms": options.pollIntervalMilliseconds = try positiveInt(try requireValue(), name: argument, allowZero: false)
            case "--paste-hold-ms": options.pasteHoldMilliseconds = try positiveInt(try requireValue(), name: argument, allowZero: true)
            case "--chunk-size": options.chunkSize = try positiveInt(try requireValue(), name: argument, allowZero: false)
            case "--chunk-delay-ms": options.chunkDelayMilliseconds = try positiveInt(try requireValue(), name: argument, allowZero: true)
            case "--mode":
                guard let mode = RunMode(rawValue: try requireValue()) else { throw EngineError.invalidArgument("--mode must be normal, single, or from") }
                options.mode = mode
            case "--strategy":
                guard let strategy = Strategy(rawValue: try requireValue()) else { throw EngineError.invalidArgument("unknown --strategy") }
                options.strategy = strategy
            case "--controlled-fixture": options.controlledFixture = true
            case "--log-path": options.logPath = try requireValue()
            case "--help", "-h": printUsageAndExit()
            default: throw EngineError.invalidArgument("unknown argument: \(argument)")
            }
            index += 1
        }
        if options.mode != .normal && options.strategy == nil { throw EngineError.invalidArgument("--strategy is required for single/from mode") }
        return options
    }

    private static func positiveInt(_ raw: String, name: String, allowZero: Bool) throws -> Int {
        guard let value = Int(raw), allowZero ? value >= 0 : value > 0 else { throw EngineError.invalidArgument("invalid integer for \(name)") }
        return value
    }
}

enum EngineError: Error, CustomStringConvertible {
    case invalidArgument(String), accessibilityUnavailable(String), clipboardUnavailable(String), targetDrift(String), eventCreationFailed(String), loggingFailed(String)
    case noFrontmostApplication, noReplacementText, uncontrolledMutationDenied

    var description: String {
        switch self {
        case .invalidArgument(let m): return m
        case .accessibilityUnavailable(let m): return "accessibility unavailable: \(m)"
        case .clipboardUnavailable(let m): return "clipboard unavailable: \(m)"
        case .targetDrift(let m): return "target drift: \(m)"
        case .eventCreationFailed(let m): return "event creation failed: \(m)"
        case .loggingFailed(let m): return "logging failed: \(m)"
        case .noFrontmostApplication: return "no frontmost application"
        case .noReplacementText: return "replacement text is empty"
        case .uncontrolledMutationDenied: return "mutation requires --controlled-fixture"
        }
    }
}

struct AXSnapshot {
    let appBundleID: String
    let pid: pid_t
    let focusedWindow: AXUIElement?
    let focusedElement: AXUIElement?
    let selectedText: String?
    let selectedRange: CFRange?
    let fullValue: String?
    let clipboardSelection: String?
    var hasSelectionContext: Bool {
        if let range = selectedRange, range.length > 0 { return true }
        if let selectedText, !selectedText.isEmpty { return true }
        if let clipboardSelection, !clipboardSelection.isEmpty { return true }
        return false
    }
}

struct AttemptLog: Codable {
    let strategy: Strategy
    let outcome: AttemptOutcome
    let verification: String
    let reason: String
    let elapsedMilliseconds: Int
}

struct RunLog: Codable {
    let timestamp: String
    let appBundleID: String
    let attemptOrder: [Strategy]
    let attempts: [AttemptLog]
    let totalElapsedMilliseconds: Int
    let finalOutcome: ReplacementOutcome
    let finalStrategy: Strategy?
    let finalReason: String
}

struct StdoutResult: Codable { let outcome: ReplacementOutcome; let strategy: Strategy?; let reason: String }

func elapsedMilliseconds(since start: DispatchTime) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
}

func sanitize(_ reason: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-:. "))
    return String(reason.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
}

func emitOutcome(_ outcome: ReplacementOutcome, strategy: Strategy?, reason: String) {
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(StdoutResult(outcome: outcome, strategy: strategy, reason: reason)), let line = String(data: data, encoding: .utf8) { print(line) }
    else { print("{\"outcome\":\"error\",\"reason\":\"stdout_encoding_failed\"}") }
}

func printUsageAndExit() -> Never {
    let strategies = Strategy.allCases.map(\.rawValue).joined(separator: "|")
    print("""
    usage: replacement-engine --controlled-fixture [options] < replacement.txt
      --delay-ms N
      --verify-timeout-ms N
      --poll-ms N
      --paste-hold-ms N
      --mode normal|single|from
      --strategy \(strategies)
      --chunk-size N
      --chunk-delay-ms N
      --log-path PATH

    Replacement text is read from stdin and is never accepted as a process argument.
    Mutation is refused unless --controlled-fixture is present.
    """)
    exit(0)
}
