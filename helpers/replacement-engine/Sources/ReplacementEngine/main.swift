import Darwin
import Foundation

let command = CommandLine.arguments.dropFirst().first

do {
    if command == "read" {
        try ProductionSelectionReadRunner().run()
    } else if command == nil || command == "replace" {
        try ProductionReplacementSessionRunner().run()
    } else {
        FileHandle.standardError.write(Data("replacement_engine_unknown_command\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("replacement_engine_failed\n".utf8))
    exit(1)
}
