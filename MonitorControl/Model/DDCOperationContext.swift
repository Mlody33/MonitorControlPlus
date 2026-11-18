// Copyright © MonitorControl contributors.

import Cocoa

/// A lock-protected lifecycle snapshot. DDC validation must never wait on the
/// main queue: existing synchronous DDC reads can already be blocking that queue.
final class DDCOperationRegistry {
  static let shared = DDCOperationRegistry()
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var activeDisplays: Set<ObjectIdentifier> = []

  func replaceDisplays(_ displays: [OtherDisplay]) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.generation &+= 1
    self.activeDisplays = Set(displays.map { ObjectIdentifier($0) })
  }

  func invalidate() {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.generation &+= 1
  }

  func snapshot() -> UInt64 {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.generation
  }

  func isCurrent(_ generation: UInt64, display: OtherDisplay) -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.generation == generation && self.activeDisplays.contains(ObjectIdentifier(display))
  }
}

/// Create on the main thread, validate before each queued operation and retry.
struct DDCOperationContext {
  private weak var display: OtherDisplay?
  private let generation: UInt64
  private let initiallyAllowed: Bool

  init(display: OtherDisplay, command: Command) {
    precondition(Thread.isMainThread)
    self.display = display
    self.generation = DDCOperationRegistry.shared.snapshot()
    self.initiallyAllowed = app.sleepID == 0 && app.reconfigureID == 0 && !display.isSw() &&
      !display.readPrefAsBool(key: .unavailableDDC, for: command)
  }

  var isValid: Bool {
    guard self.initiallyAllowed, let display = self.display else { return false }
    return DDCOperationRegistry.shared.isCurrent(self.generation, display: display)
  }
}
