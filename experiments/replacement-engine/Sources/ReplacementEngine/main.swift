import Darwin
import Foundation

let exitCode: Int32
do {
    let options = try Options.parse(CommandLine.arguments)
    var replacement = ""
    while let line = readLine(strippingNewline: false) { replacement += line }
    guard !replacement.isEmpty else { throw EngineError.noReplacementText }
    let outcome = ReplacementEngine(options: options, replacement: replacement).run()
    switch outcome {
    case .verifiedReplaced: exitCode = 0
    case .notReplaced: exitCode = 2
    case .replacementDispatchedUnverified: exitCode = 3
    case .error: exitCode = 1
    }
} catch let error as EngineError {
    emitOutcome(.error, strategy: nil, reason: sanitize(error.description)); exitCode = 1
} catch {
    emitOutcome(.error, strategy: nil, reason: "unexpected_error"); exitCode = 1
}
exit(exitCode)
