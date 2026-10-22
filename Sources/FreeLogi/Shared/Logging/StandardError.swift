import Foundation

func printToStandardError(_ message: String) {
    let line = Data((message + "\n").utf8)
    FileHandle.standardError.write(line)
}
