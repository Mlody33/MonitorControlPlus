import Cocoa

let DEBUG_MACOS10 = false
let prefs = UserDefaults(suiteName: "local.MonitorControlPlus.ui-tests.\(UUID().uuidString)")!
final class TestApp { var sleepID = 0; var reconfigureID = 0 }
let app = TestApp()
class Display { var identifier: CGDirectDisplayID = 1 }
final class AppleDisplay: Display {
  func getAppleBrightness() -> Float { 0.5 }
  func setBrightness(_ value: Float) -> Bool { true }
}
struct DisplayPowerResult { let sent: Bool; let reportedMode: UInt16? }
final class OtherDisplay: Display {
  var name = "P27h-20"
  var input: UInt16 = 0x31
  var dpmsOffRequested = false
  var reportedPowerMode: UInt16? = 1
  var powerCallbacks: [() -> Void] = []
  func refreshPowerMode(completion: @escaping () -> Void) { self.powerCallbacks.append(completion) }
  func setDisplayPower(awake: Bool, completion: (DisplayPowerResult) -> Void) { completion(DisplayPowerResult(sent: true, reportedMode: 1)) }
  func refreshInputSources(reloadCapabilities: Bool, completion: (InputSourceSnapshot) -> Void) {
    completion(InputSourceSnapshot(sources: [UInt16(0x0F), 0x11, 0x31].map { DDCInputSource(code: $0, displayName: self.name) }, current: self.input))
  }
  func switchInput(to: UInt16, completion: (InputSwitchResult) -> Void) { completion(.confirmed(to)) }
  func readPrefAsString(key: PrefKey) -> String { "" }
  func setupSliderCurrentValue(command: Command) -> Float { 0 }
  func isSw() -> Bool { false }
  func readPrefAsInt(for command: Command) -> Int { 0 }
  func readPrefAsBool(key: PrefKey) -> Bool { false }
  func toggleMute(fromVolumeSlider: Bool) {}
  func setBrightness(_ value: Float) -> Bool { true }
  func writeDDCValues(command: Command, value: UInt16) {}
  func convValueToDDC(for command: Command, from value: Float) -> UInt16 { UInt16(value * 100) }
  func savePref(_ value: Float, for command: Command) {}
}

@main
struct SliderUITests {
  static func main() {
    _ = NSApplication.shared
    let display = OtherDisplay()
    let source = InputSourceSlider(display: display, width: 248)
    source.refresh()
    assert(source.slider.doubleValue == 1 && display.powerCallbacks.count == 1)
    let sourceCell = source.slider.cell as! SliderHandler.MCSliderCell
    sourceCell.isTracking = true
    source.slider.doubleValue = 0
    display.powerCallbacks.removeFirst()()
    assert(source.slider.doubleValue == 0, "A delayed power read must not reset an active drag")
    sourceCell.isTracking = false
    source.refresh()
    display.powerCallbacks.removeFirst()()
    assert(source.slider.doubleValue == 1)

    prefs.set(true, forKey: PrefKey.enableSliderPercent.rawValue)
    let handler = SliderHandler(display: nil, command: .audioSpeakerVolume)
    let cell = handler.slider!.cell as! SliderHandler.MCSliderCell
    let track = cell.barRect(flipped: false)
    func rect(gap: Double) -> NSRect {
      cell.handleRect(in: track, value: (gap - 12) / Double(track.width - 60))
    }
    assert(rect(gap: 27).width == 60)
    let start = rect(gap: 29)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
    let mid = rect(gap: 29)
    assert(mid.width > 48 && mid.width < 60 && abs(mid.maxX - start.maxX) < 0.001)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    assert(rect(gap: 29).width == 48)
    assert(rect(gap: 26).width == 48, "Hysteresis must keep icon outside")
    let reverse = rect(gap: 23)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    let absorbed = rect(gap: 23)
    assert(absorbed.width == 60 && abs(absorbed.maxX - reverse.maxX) < 0.001)

    handler.slider!.doubleValue = 0
    assert(cell.animatedValue == 0)
    handler.slider!.doubleValue = 1
    assert(cell.animatedValue == 0)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
    assert(cell.animatedValue > 0 && cell.animatedValue < 1)
    let position = cell.animatedValue
    handler.slider!.doubleValue = 0
    assert(abs(cell.animatedValue - position) < 0.001, "Reversal must be continuous")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    assert(cell.animatedValue == 0)
    cell.isTracking = true
    handler.slider!.doubleValue = 0.5
    assert(cell.animatedValue == 0.5, "Dragging remains direct")
    print("PASS: delayed power refresh preserves dragging; shared animations, reversal, icon thresholds and right-edge anchoring")
  }
}
