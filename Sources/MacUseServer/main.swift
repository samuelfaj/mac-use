import Foundation
import MacUse

@main
struct MacUseServer {
    static func main() async {
        let handler = ManagedComputerUseMCP()
        while let line = readLine() {
            if let response = await handler.handle(line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
    }
}
