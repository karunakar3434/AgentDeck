// Sends a debug command to a running Debug build of AgentDeck.
// Build: swiftc -O scripts/debugctl.swift -o build/debugctl
// Usage: build/debugctl snapshot /tmp/main.png | section history | open 0 | inspect 1 | resize 420 800 …
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.karun.AgentDeck.debug"), object: nil,
    userInfo: ["args": args], deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
