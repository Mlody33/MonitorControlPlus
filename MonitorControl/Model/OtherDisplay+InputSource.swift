// Copyright © MonitorControl contributors.

import Cocoa

extension OtherDisplay {
  func refreshInputSources(reloadCapabilities: Bool = false, completion: @escaping (InputSourceSnapshot) -> Void) {
    let context = DDCOperationContext(display: self, command: .inputSelect)
    guard context.isValid, !self.inputSwitchPending, !self.powerRequestPending, !self.dpmsOffRequested
    else {
      completion(InputSourceSnapshot(sources: [], current: nil))
      return
    }
    let existingCodes = reloadCapabilities ? nil : self.cachedInputSourceCodes
    let fallbackCodes = self.cachedInputSourceCodes ?? []
    DisplayManager.shared.globalDDCQueue.async {
      guard context.isValid else {
        DispatchQueue.main.async { completion(InputSourceSnapshot(sources: [], current: nil)) }
        return
      }
      let codes = existingCodes ?? (Arm64DDC.isArm64 ? Arm64DDC.readInputCapabilities(service: self.arm64avService) : self.ddc?.readInputCapabilities()) ?? fallbackCodes
      let current = self.readCurrentInputSource(context: context)
      DispatchQueue.main.async {
        guard context.isValid else {
          completion(InputSourceSnapshot(sources: [], current: nil))
          return
        }
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
    let context = DDCOperationContext(display: self, command: .inputSelect)
    guard context.isValid, !self.inputSwitchPending, !self.powerRequestPending, !self.dpmsOffRequested,
          self.cachedInputSourceCodes?.contains(value) == true
    else {
      completion(.unconfirmed(nil))
      return
    }
    self.inputSwitchPending = true
    DisplayManager.shared.globalDDCQueue.async {
      self.writeInputSource(value, context: context)
      self.verifyInputSource(value, remaining: 4, context: context, completion: completion)
    }
  }

  private func readCurrentInputSource(context: DDCOperationContext) -> UInt16? {
    guard context.isValid else { return nil }
    let command = self.getRemapControlCodes(command: .inputSelect).first ?? Command.inputSelect.rawValue
    let value: UInt16?
    if Arm64DDC.isArm64 {
      value = Arm64DDC.read(service: self.arm64avService, command: command, numOfRetryAttemps: 1)?.current
    } else {
      value = self.ddc?.read(command: command, tries: 2)?.0
    }
    return value == 0 ? nil : value
  }

  private func writeInputSource(_ value: UInt16, context: DDCOperationContext) {
    guard context.isValid else { return }
    let command = self.getRemapControlCodes(command: .inputSelect).first ?? Command.inputSelect.rawValue
    if Arm64DDC.isArm64 {
      _ = Arm64DDC.write(service: self.arm64avService, command: command, value: value)
    } else {
      _ = self.ddc?.write(command: command, value: value, errorRecoveryWaitTime: 2000)
    }
  }

  private func verifyInputSource(_ value: UInt16, remaining: Int, context: DDCOperationContext, completion: @escaping (InputSwitchResult) -> Void) {
    DisplayManager.shared.globalDDCQueue.asyncAfter(deadline: .now() + 2) {
      let canRead = context.isValid
      let actual = canRead ? self.readCurrentInputSource(context: context) : nil
      if actual == value || remaining == 1 || !canRead {
        DispatchQueue.main.async {
          self.inputSwitchPending = false
          completion(context.isValid && actual == value ? .confirmed(value) : .unconfirmed(context.isValid ? actual : nil))
        }
        return
      }
      // Give a temporarily unresponsive input time to settle before retrying.
      if actual != nil || remaining == 2 { self.writeInputSource(value, context: context) }
      self.verifyInputSource(value, remaining: remaining - 1, context: context, completion: completion)
    }
  }
}
