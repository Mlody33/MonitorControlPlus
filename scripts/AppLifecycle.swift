import AppKit

let identifier = "local.mateusz.MonitorControlPlus"
let command = CommandLine.arguments.dropFirst().first ?? ""
let applications = NSWorkspace.shared.runningApplications.filter {
  $0.bundleIdentifier == identifier || $0.bundleURL?.lastPathComponent == "MonitorControlPlus.app"
}
if command == "quit" {
  for application in applications {
    guard application.terminate() else {
      fputs("Cannot quit MonitorControlPlus; close it before updating.\n", stderr)
      exit(1)
    }
  }
  let deadline = Date().addingTimeInterval(15)
  while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }
  guard applications.allSatisfy({ $0.isTerminated }) else {
    fputs("MonitorControlPlus is still running; installation was not replaced.\n", stderr)
    exit(1)
  }
} else if command == "check", CommandLine.arguments.count == 3 {
  let expected = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
  guard applications.contains(where: { $0.bundleIdentifier == identifier && $0.bundleURL?.standardizedFileURL == expected }) else {
    fputs("The updated MonitorControlPlus is not running from the installation path.\n", stderr)
    exit(1)
  }
  print("Confirmed running: \(expected.path)")
} else {
  exit(2)
}
