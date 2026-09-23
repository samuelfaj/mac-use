import Foundation
import MacUse

@main
struct MacUseServer {
    static func main() async {
        let args = CommandLine.arguments
        if args.count > 1 {
            do {
                switch args[1] {
                case ChromeProfileConnection.hostArgument:
                    guard args.count == 3 else { throw NSError(domain: "mac-use", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chrome origin required"]) }
                    try ChromeProfileConnection.runHost(origin: args[2])
                case "install-chrome-host":
                    guard args.count == 3 else { throw NSError(domain: "mac-use", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chrome extension ID required"]) }
                    try ChromeProfileConnection.install(executable: URL(fileURLWithPath: args[0]).standardizedFileURL.path, extensionID: args[2])
                    FileHandle.standardError.write(Data("Chrome native host registered. Click the mac-use extension icon to connect.\n".utf8))
                default:
                    throw NSError(domain: "mac-use", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown command"])
                }
            } catch {
                FileHandle.standardError.write(Data("mac-use: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        let handler = ManagedComputerUseMCP()
        while let line = readLine() {
            if let response = await handler.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}
