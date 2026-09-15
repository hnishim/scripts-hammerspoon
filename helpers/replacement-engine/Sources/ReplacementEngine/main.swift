import Darwin
import Foundation

do {
    try ProductionReplacementSessionRunner().run()
} catch {
    FileHandle.standardError.write(Data("replacement_engine_failed\n".utf8))
    exit(1)
}
