// Copyright © MonitorControl contributors.

import Cocoa

extension OtherDisplay {
  func refreshInputSources(reloadCapabilities: Bool = false, completion: @escaping (InputSourceSnapshot) -> Void) {
    guard !self.isSw(), !self.readPrefAsBool(key: .unavailableDDC, for: .inputSelect),
          !self.inputSwitchPending, !self.powerRequestPending, app.sleepID == 0, app.reconfigureID == 0,
          DisplayManager.shared.getOtherDisplays().contains(where: { $0 === self })
    else {
      completion(InputSourceSnapshot(sources: [], current: nil))
      return
    }
    let existingCodes = reloadCapabilities ? nil : self.cachedInputSourceCodes
    let fallbackCodes = self.cachedInputSourceCodes ?? []
    DisplayManager.shared.globalDDCQueue.async {
      guard app.sleepID == 0, app.reconfigureID == 0 else {
        DispatchQueue.main.async { completion(InputSourceSnapshot(sources: [], current: nil)) }
        return
      }
      let codes = existingCodes ?? (Arm64DDC.isArm64 ? Arm64DDC.readInputCapabilities(service: self.arm64avService) : self.ddc?.readInputCapabilities()) ?? fallbackCodes
      let current = self.readCurrentInputSource()
      DispatchQueue.main.async {
        var available = codes
        // Some monitors omit the selected source from their capabilities.
        if let current = current, !available.contains(current) { available.append(current) }
        self.cachedInputSourceCodes = available
        completion(InputSourceSnapshot(sources: available.map { DDCInputSource(code: $0, displayName: self.name) }, current: current))
      }
    }
  }

  /// A discrete, verified action, independent of percentage sliders and startup restore.
  func switchInput(to value: UInt16, completion: @escaping (InputSwitchResult) -> Void) {
    guard !self.inputSwitchPending, !self.powerRequestPending, !self.dpmsOffRequested, !self.isSw(), app.sleepID == 0, app.reconfigureID == 0,
          !self.readPrefAsBool(key: .unavailableDDC, for: .inputSelect),
          self.cachedInputSourceCodes?.contains(value) == true,
          DisplayManager.shared.getOtherDisplays().contains(where: { $0 === self })
    else {
      completion(.unconfirmed(nil))
      return
    }
    self.inputSwitchPending = true
    DisplayManager.shared.globalDDCQueue.async {
      self.writeInputSource(value)
      self.verifyInputSource(value, remaining: 4, completion: completion)
    }
  }

  private func readCurrentInputSource() -> UInt16? {
    let command = self.getRemapControlCodes(command: .inputSelect).first ?? Command.inputSelect.rawValue
    let value: UInt16?
    if Arm64DDC.isArm64 {
      value = Arm64DDC.read(service: self.arm64avService, command: command, numOfRetryAttemps: 1)?.current
    } else {
      value = self.ddc?.read(command: command, tries: 2)?.0
    }
    return value == 0 ? nil : value
  }

  private func writeInputSource(_ value: UInt16) {
    guard app.sleepID == 0, app.reconfigureID == 0, !self.isSw(), !self.readPrefAsBool(key: .unavailableDDC, for: .inputSelect) else { return }
    let command = self.getRemapControlCodes(command: .inputSelect).first ?? Command.inputSelect.rawValue
    if Arm64DDC.isArm64 {
      _ = Arm64DDC.write(service: self.arm64avService, command: command, value: value)
    } else {
      _ = self.ddc?.write(command: command, value: value, errorRecoveryWaitTime: 2000)
    }
  }

  private func verifyInputSource(_ value: UInt16, remaining: Int, completion: @escaping (InputSwitchResult) -> Void) {
    DisplayManager.shared.globalDDCQueue.asyncAfter(deadline: .now() + 2) {
      let canRead = app.sleepID == 0 && app.reconfigureID == 0 && !self.isSw()
      let actual = canRead ? self.readCurrentInputSource() : nil
      if actual == value || remaining == 1 || !canRead {
        DispatchQueue.main.async {
          self.inputSwitchPending = false
          completion(actual == value ? .confirmed(value) : .unconfirmed(actual))
        }
        return
      }
      // Give a temporarily unresponsive input time to settle before retrying.
      if actual != nil || remaining == 2 { self.writeInputSource(value) }
      self.verifyInputSource(value, remaining: remaining - 1, completion: completion)
    }
  }
}
