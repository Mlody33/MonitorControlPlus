import Cocoa

final class TestQueue {
  private let queue = DispatchQueue(label: "DisplayPowerTests")
  func suspend() { self.queue.suspend() }
  func resume() { self.queue.resume() }
  func async(execute: @escaping () -> Void) { self.queue.async(execute: execute) }
  func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { self.queue.async(execute: execute) }
}
final class DisplayManager {
  static let shared = DisplayManager()
  let globalDDCQueue = TestQueue()
  var displays: [OtherDisplay] = [] {
    didSet { DDCOperationRegistry.shared.replaceDisplays(self.displays) }
  }
  func getOtherDisplays() -> [OtherDisplay] { self.displays }
}
final class TestApp { var sleepID = 0; var reconfigureID = 0 }
let app = TestApp()
enum PrefKey { case unavailableDDC }
final class IntelDDC {
  func read(command: UInt8, tries: Int) -> (UInt16, UInt16)? { nil }
  func write(command: UInt8, value: UInt16, errorRecoveryWaitTime: Int, numofWriteCycles: Int) -> Bool { false }
}
enum Arm64DDC {
  static let isArm64 = true
  static var reads: [UInt16?] = []
  static var writes: [(Int?, UInt8, UInt16)] = []
  static var success = true
  static var readCount = 0
  static var onWrite: (() -> Void)?
  static func read(service: Int?, command: UInt8, numOfRetryAttemps: Int) -> (current: UInt16, max: UInt16)? {
    self.readCount += 1
    assert(command == 0xD6)
    guard !self.reads.isEmpty, let value = self.reads.removeFirst() else { return nil }
    return (value, 0)
  }
  static func write(service: Int?, command: UInt8, value: UInt16, numOfWriteCycles: Int, numOfRetryAttemps: Int) -> Bool {
    assert(numOfWriteCycles == 1 && numOfRetryAttemps == 0)
    self.writes.append((service, command, value))
    self.onWrite?()
    return self.success
  }
}
final class OtherDisplay {
  var powerRequestPending = false
  var powerRefreshPending = false
  var inputSwitchPending = false
  var dpmsOffRequested = false
  var reportedPowerMode: UInt16?
  var arm64avService: Int? = 7
  var ddc: IntelDDC?
  var software = false
  func isSw() -> Bool { self.software }
  func readPrefAsBool(key: PrefKey, for command: Command) -> Bool { false }
  func getRemapControlCodes(command: Command) -> [UInt8] { [] }
}
@main
struct DisplayPowerTests {
  static func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    assert(condition(), "Timed out waiting for power callback")
  }
  static func main() {
    let display = OtherDisplay()
    let other = OtherDisplay()
    other.arm64avService = 8
    DisplayManager.shared.displays = [display, other]
    Arm64DDC.reads = [1]
    var read = false
    display.refreshPowerMode { read = true; assert(Thread.isMainThread) }
    self.wait { read }
    assert(display.reportedPowerMode == 1 && !display.dpmsOffRequested)
    assert(Arm64DDC.writes.isEmpty, "Refresh must never write power settings")
    Arm64DDC.reads = [nil]
    var result: DisplayPowerResult?
    display.setDisplayPower(awake: false) { result = $0; assert(Thread.isMainThread) }
    assert(display.powerRequestPending)
    var duplicate: DisplayPowerResult?
    display.setDisplayPower(awake: false) { duplicate = $0 }
    assert(duplicate?.sent == false)
    self.wait { result != nil }
    assert(result!.sent && result!.reportedMode == nil && display.dpmsOffRequested)
    assert(Arm64DDC.writes.count == 1 && Arm64DDC.writes[0].0 == 7 && Arm64DDC.writes[0].1 == 0xD6 && Arm64DDC.writes[0].2 == 4)
    Arm64DDC.reads = [nil, 1]
    result = nil
    display.setDisplayPower(awake: true) { result = $0 }
    self.wait { result != nil }
    assert(result!.reportedMode == 1 && !display.dpmsOffRequested && !display.powerRequestPending)
    assert(Arm64DDC.writes.suffix(2).allSatisfy { $0.0 == 7 && $0.2 == 1 })
    assert(!Arm64DDC.writes.contains { $0.2 == 5 }, "Never send hard off")
    let count = Arm64DDC.writes.count
    display.inputSwitchPending = true
    display.setDisplayPower(awake: false) { assert(!$0.sent) }
    assert(Arm64DDC.writes.count == count)
    display.inputSwitchPending = false
    DisplayManager.shared.displays = [other]
    display.setDisplayPower(awake: false) { assert(!$0.sent) }
    assert(Arm64DDC.writes.count == count)
    // Removal while a request is waiting in the queue must cancel its write.
    DisplayManager.shared.displays = [display, other]
    let queue = DisplayManager.shared.globalDDCQueue
    queue.suspend()
    result = nil
    display.setDisplayPower(awake: false) { result = $0 }
    DisplayManager.shared.displays = [other]
    queue.resume()
    self.wait { result != nil }
    assert(!result!.sent && !display.powerRequestPending && Arm64DDC.writes.count == count)

    // A sleep/wake cycle invalidates queued work even when the same instance remains.
    DisplayManager.shared.displays = [display, other]
    queue.suspend()
    result = nil
    display.setDisplayPower(awake: true) { result = $0 }
    DDCOperationRegistry.shared.invalidate()
    queue.resume()
    self.wait { result != nil }
    assert(!result!.sent && Arm64DDC.writes.count == count)

    // A lifecycle change during wake must cancel subsequent retries.
    Arm64DDC.onWrite = { DDCOperationRegistry.shared.invalidate() }
    result = nil
    display.setDisplayPower(awake: true) { result = $0 }
    self.wait { result != nil }
    assert(!result!.sent && Arm64DDC.writes.count == count + 1)
    Arm64DDC.onWrite = nil

    // Repeated polling during one blocked read queues only a single transaction.
    queue.suspend()
    let readsBefore = Arm64DDC.readCount
    Arm64DDC.reads = [1]
    read = false
    display.refreshPowerMode { read = true }
    for _ in 0..<20 { display.refreshPowerMode {} }
    assert(display.powerRefreshPending)
    queue.resume()
    self.wait { read }
    assert(!display.powerRefreshPending && Arm64DDC.readCount == readsBefore + 1)
    print("PASS: read-only refresh, one selected monitor, DPMS off 04/on 01, bounded wake retries, no hard off, no duplicate/stale/source-conflicting writes")
  }
}
