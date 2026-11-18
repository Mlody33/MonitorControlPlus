import Cocoa

final class TestQueue {
  private let queue = DispatchQueue(label: "InputSourceOperationTests")
  func suspend() { self.queue.suspend() }
  func resume() { self.queue.resume() }
  func async(execute: @escaping () -> Void) { self.queue.async(execute: execute) }
  func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { self.queue.async(execute: execute) }
}
final class DisplayManager {
  static let shared = DisplayManager()
  let globalDDCQueue = TestQueue() // Virtualize only the retry delay.
  var displays: [OtherDisplay] = [] {
    didSet { DDCOperationRegistry.shared.replaceDisplays(self.displays) }
  }
  func getOtherDisplays() -> [OtherDisplay] { self.displays }
}
final class TestApp { var sleepID = 0; var reconfigureID = 0 }
let app = TestApp()
enum PrefKey { case unavailableDDC }
final class IntelDDC {
  func readInputCapabilities() -> [UInt16]? { nil }
  func read(command: UInt8, tries: Int) -> (UInt16, UInt16)? { nil }
  func write(command: UInt8, value: UInt16, errorRecoveryWaitTime: Int) -> Bool { false }
}
enum Arm64DDC {
  static let isArm64 = true
  static var reads: [UInt16?] = []
  static var capabilitiesReads = 0
  static var onWrite: (() -> Void)?
  static var writes: [(Int?, UInt8, UInt16)] = []
  static func readInputCapabilities(service: Int?) -> [UInt16]? { self.capabilitiesReads += 1; return [0x0F, 0x11, 0x31] }
  static func read(service: Int?, command: UInt8, numOfRetryAttemps: Int) -> (current: UInt16, max: UInt16)? {
    guard !self.reads.isEmpty, let value = self.reads.removeFirst() else { return nil }
    return (value, 0)
  }
  static func write(service: Int?, command: UInt8, value: UInt16) -> Bool {
    self.writes.append((service, command, value))
    self.onWrite?()
    return true
  }
}
final class OtherDisplay {
  var cachedInputSourceCodes: [UInt16]?
  var inputSwitchPending = false
  var powerRequestPending = false
  var dpmsOffRequested = false
  var name = "P27h-20"
  var arm64avService: Int? = 7
  var ddc: IntelDDC?
  var software = false
  func isSw() -> Bool { self.software }
  func readPrefAsBool(key: PrefKey, for command: Command) -> Bool { false }
  func getRemapControlCodes(command: Command) -> [UInt8] { [] }
}

@main
struct InputSourceOperationTests {
  static func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    assert(condition(), "Timed out waiting for callback")
  }
  static func main() {
    let display = OtherDisplay()
    let other = OtherDisplay()
    other.arm64avService = 8
    DisplayManager.shared.displays = [display, other]
    Arm64DDC.reads = [0x31]
    var snapshot: InputSourceSnapshot?
    display.refreshInputSources { snapshot = $0; assert(Thread.isMainThread) }
    self.wait { snapshot != nil }
    assert(snapshot?.sources.count == 3 && snapshot?.selectedIndex == 2)
    Arm64DDC.reads = [nil, 0x31, 0x11]
    var result: InputSwitchResult?
    display.switchInput(to: 0x11) { result = $0; assert(Thread.isMainThread) }
    assert(display.inputSwitchPending)
    var duplicateRejected = false
    display.switchInput(to: 0x31) { if case .unconfirmed = $0 { duplicateRejected = true } }
    assert(duplicateRejected)
    self.wait { result != nil }
    if case .confirmed(0x11) = result! {} else { assertionFailure("Readback did not confirm HDMI") }
    assert(!display.inputSwitchPending)
    assert(Arm64DDC.writes.count == 2)
    assert(Arm64DDC.writes.allSatisfy { $0.0 == 7 && $0.1 == 0x60 && $0.2 == 0x11 })
    let priorCount = Arm64DDC.writes.count
    display.switchInput(to: 0xFF) { if case .unconfirmed = $0 {} else { assertionFailure() } }
    assert(Arm64DDC.writes.count == priorCount)
    Arm64DDC.reads = [0x11, 0x11, 0x11, 0x11]
    result = nil
    display.switchInput(to: 0x31) { result = $0 }
    self.wait { result != nil }
    if case .unconfirmed(0x11) = result! {} else { assertionFailure("Must report actual input after failed switch") }
    assert(!display.inputSwitchPending)
    app.sleepID = 1
    result = nil
    display.switchInput(to: 0x31) { result = $0 }
    if case .unconfirmed(nil) = result! {} else { assertionFailure() }
    app.sleepID = 0
    let queue = DisplayManager.shared.globalDDCQueue
    let writesBefore = Arm64DDC.writes.count
    queue.suspend()
    result = nil
    display.switchInput(to: 0x31) { result = $0 }
    DisplayManager.shared.displays = [other]
    queue.resume()
    self.wait { result != nil }
    assert(Arm64DDC.writes.count == writesBefore && !display.inputSwitchPending)

    DisplayManager.shared.displays = [display, other]
    queue.suspend()
    result = nil
    display.switchInput(to: 0x31) { result = $0 }
    DDCOperationRegistry.shared.invalidate()
    queue.resume()
    self.wait { result != nil }
    assert(Arm64DDC.writes.count == writesBefore)

    Arm64DDC.onWrite = {
      DispatchQueue.main.sync { DisplayManager.shared.displays = [other] }
    }
    result = nil
    display.switchInput(to: 0x31) { result = $0 }
    self.wait { result != nil }
    assert(Arm64DDC.writes.count == writesBefore + 1, "No retries after removal")
    Arm64DDC.onWrite = nil
    DisplayManager.shared.displays = [display, other]
    Arm64DDC.reads = [0x31]
    snapshot = nil
    display.refreshInputSources { snapshot = $0 }
    self.wait { snapshot != nil }
    assert(Arm64DDC.capabilitiesReads == 1, "Reuse capabilities for the same display")
    print("PASS: real source operations confirm readback, tolerate settling, retry, reject concurrent/unknown/sleep requests and target one display")
  }
}
