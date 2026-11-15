// Copyright © MonitorControl contributors.

import Cocoa

struct DisplayPowerResult {
  let sent: Bool
  let reportedMode: UInt16?
}

extension OtherDisplay {
  func refreshPowerMode(completion: @escaping () -> Void) {
    guard !self.isSw(), !self.powerRequestPending, !self.inputSwitchPending,
          !self.readPrefAsBool(key: .unavailableDDC, for: .powerMode),
          app.sleepID == 0, app.reconfigureID == 0
    else { completion(); return }
    DisplayManager.shared.globalDDCQueue.async {
      let mode = self.readDisplayPowerMode()
      DispatchQueue.main.async {
        self.recordDisplayPowerMode(mode)
        completion()
      }
    }
  }

  /// Deliberate per-display power action. Never restored on startup or wake.
  /// DPMS off is 0x04; the write-only hard-off command 0x05 is not used.
  func setDisplayPower(awake: Bool, completion: @escaping (DisplayPowerResult) -> Void) {
    guard !self.isSw(), !self.powerRequestPending, !self.inputSwitchPending,
          !self.readPrefAsBool(key: .unavailableDDC, for: .powerMode),
          app.sleepID == 0, app.reconfigureID == 0,
          DisplayManager.shared.getOtherDisplays().contains(where: { $0 === self })
    else { completion(DisplayPowerResult(sent: false, reportedMode: nil)); return }
    self.powerRequestPending = true
    self.performPowerRequest(awake: awake, attempts: awake ? 3 : 1, completion: completion)
  }

  private func readDisplayPowerMode() -> UInt16? {
    guard app.sleepID == 0, app.reconfigureID == 0 else { return nil }
    let command = self.getRemapControlCodes(command: .powerMode).first ?? Command.powerMode.rawValue
    let mode: UInt16?
    if Arm64DDC.isArm64 {
      mode = Arm64DDC.read(service: self.arm64avService, command: command, numOfRetryAttemps: 0)?.current
    } else {
      mode = self.ddc?.read(command: command, tries: 1)?.0
    }
    guard let mode = mode, (1 ... 5).contains(mode) else { return nil }
    return mode
  }

  private func recordDisplayPowerMode(_ mode: UInt16?) {
    self.reportedPowerMode = mode
    if let mode = mode { self.dpmsOffRequested = mode != 1 }
  }

  private func performPowerRequest(awake: Bool, attempts: Int, completion: @escaping (DisplayPowerResult) -> Void) {
    DisplayManager.shared.globalDDCQueue.async {
      guard app.sleepID == 0, app.reconfigureID == 0, !self.isSw() else {
        DispatchQueue.main.async {
          self.powerRequestPending = false
          completion(DisplayPowerResult(sent: false, reportedMode: nil))
        }
        return
      }
      let command = self.getRemapControlCodes(command: .powerMode).first ?? Command.powerMode.rawValue
      let value: UInt16 = awake ? 0x01 : 0x04
      let sent = Arm64DDC.isArm64
        ? Arm64DDC.write(service: self.arm64avService, command: command, value: value, numOfWriteCycles: 1, numOfRetryAttemps: 0)
        : (self.ddc?.write(command: command, value: value, errorRecoveryWaitTime: 2000, numofWriteCycles: 1) ?? false)
      DisplayManager.shared.globalDDCQueue.asyncAfter(deadline: .now() + 1) {
        let mode = self.readDisplayPowerMode()
        if awake, mode != 1, attempts > 1, app.sleepID == 0, app.reconfigureID == 0 {
          self.performPowerRequest(awake: true, attempts: attempts - 1, completion: completion)
          return
        }
        DispatchQueue.main.async {
          // Sleeping monitors can stop replying. Preserve the wake action after
          // a sent off request, without treating transport success as readback.
          if sent, !awake { self.dpmsOffRequested = true }
          self.recordDisplayPowerMode(mode)
          self.powerRequestPending = false
          completion(DisplayPowerResult(sent: sent, reportedMode: mode))
        }
      }
    }
  }
}
