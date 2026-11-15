// Copyright © MonitorControl contributors.

import AppKit

final class InputSourceSlider: NSView {
  private final class SourceCell: SliderHandler.MCSliderCell {
    var sourceNames: [String] = []
    override var animatesWhileTracking: Bool { true }

    override func barRect(flipped: Bool) -> NSRect {
      guard let view = self.controlView else { return .zero }
      return NSRect(x: 2, y: (view.bounds.height - 22) / 2, width: max(0, view.bounds.width - 4), height: 22)
    }

    override func knobRect(flipped: Bool) -> NSRect {
      let track = self.barRect(flipped: flipped)
      let count = max(1, self.sourceNames.count)
      let width = track.width / CGFloat(count)
      let position = CGFloat(min(1, max(0, self.doubleValue))) * CGFloat(count - 1)
      return NSRect(x: track.minX + position * width, y: track.minY, width: width, height: track.height)
    }

    override func drawTickMarks() {}
    override func drawKnob(_ rect: NSRect) {} // The thumb and labels are drawn together.

    override func drawBar(inside rect: NSRect, flipped: Bool) {
      let track = self.barRect(flipped: flipped)
      let background = NSBezierPath(roundedRect: track, xRadius: 11, yRadius: 11)
      self.barFillColor.setFill()
      background.fill()
      self.barStrokeColor.setStroke()
      background.stroke()
      guard !self.sourceNames.isEmpty else { return }
      // Keep knobRect at the logical value for AppKit hit testing; animate only
      // the painted capsule between the source segments.
      let segmentWidth = track.width / CGFloat(self.sourceNames.count)
      let position = CGFloat(self.animatedValue) * CGFloat(self.sourceNames.count - 1)
      let thumbRect = NSRect(x: track.minX + position * segmentWidth, y: track.minY, width: segmentWidth, height: track.height)
      let thumb = NSBezierPath(roundedRect: thumbRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
      (self.isTracking ? self.knobFillColorTracking : self.knobFillColor).setFill()
      thumb.fill()
      self.knobStrokeColor.setStroke()
      thumb.stroke()
      let selected = Int((self.doubleValue * Double(self.sourceNames.count - 1)).rounded())
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      paragraph.lineBreakMode = .byTruncatingTail
      for (index, name) in self.sourceNames.enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.systemFont(ofSize: 10, weight: index == selected ? .medium : .regular),
          .foregroundColor: index == selected ? NSColor.black.withAlphaComponent(0.8) : NSColor.labelColor.withAlphaComponent(0.65),
          .paragraphStyle: paragraph,
        ]
        let labelRect = NSRect(x: track.minX + CGFloat(index) * segmentWidth + 2, y: track.midY - 6.5, width: max(0, segmentWidth - 4), height: 13)
        (name as NSString).draw(in: labelRect, withAttributes: attributes)
      }
    }
  }

  private final class PowerButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
      let circle = NSBezierPath(ovalIn: self.bounds.insetBy(dx: 0.5, dy: 0.5))
      (self.state == .on || self.isHighlighted ? NSColor.white : NSColor.systemGray.withAlphaComponent(0.2)).setFill()
      circle.fill()
      NSColor.systemGray.withAlphaComponent(0.5).setStroke()
      circle.stroke()
      if #available(macOS 11.0, *) {
        var icon = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        if #available(macOS 12.0, *) {
          icon = icon?.withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: self.state == .on ? .controlAccentColor : .labelColor))
        }
        icon?.draw(in: self.bounds.insetBy(dx: 5, dy: 5), from: .zero, operation: .sourceOver, fraction: self.isEnabled ? 0.75 : 0.3, respectFlipped: true, hints: nil)
      }
    }
  }

  let display: OtherDisplay
  let slider = SliderHandler.MCSlider(frame: .zero)
  private var snapshot = InputSourceSnapshot(sources: [], current: nil)
  private var refreshing = false
  private var switching = false
  private var powering = false
  private let powerButton = PowerButton(frame: .zero)

  init(display: OtherDisplay, width: CGFloat) {
    self.display = display
    let width = max(width, 248)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 56))
    let title = NSTextField(labelWithString: "")
    let friendlyName = display.readPrefAsString(key: .friendlyName)
    title.stringValue = friendlyName.isEmpty ? display.name : friendlyName
    title.font = .systemFont(ofSize: 11, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    title.frame = NSRect(x: 17, y: 36, width: width - 34, height: 16)
    title.toolTip = title.stringValue
    self.addSubview(title)
    self.slider.cell = SourceCell()
    self.slider.minValue = 0
    self.slider.maxValue = 1
    self.slider.isContinuous = false // Send one command when the user releases the thumb.
    self.slider.allowsTickMarkValuesOnly = true
    self.slider.frame = NSRect(x: 15, y: 5, width: width - 60, height: 30)
    self.slider.target = self
    self.slider.action = #selector(self.sourceChanged(_:))
    self.slider.setAccessibilityLabel(NSLocalizedString("Input source", comment: "Source slider") + " — " + title.stringValue)
    self.addSubview(self.slider)
    self.powerButton.frame = NSRect(x: width - 39, y: 9, width: 22, height: 22)
    self.powerButton.isBordered = false
    self.powerButton.setButtonType(.momentaryChange)
    self.powerButton.target = self
    self.powerButton.action = #selector(self.togglePower(_:))
    self.addSubview(self.powerButton)
    self.apply(self.snapshot)
  }

  required init?(coder: NSCoder) { nil }

  func refresh(reloadCapabilities: Bool = false) {
    guard !self.refreshing, !self.switching, !self.powering, (self.slider.cell as? SourceCell)?.isTracking != true else { return }
    if self.display.dpmsOffRequested {
      self.refreshPowerButton()
      return
    }
    self.refreshing = true
    self.display.refreshInputSources(reloadCapabilities: reloadCapabilities) { [weak self] snapshot in
      guard let self = self else { return }
      self.refreshing = false
      guard !self.switching, !self.powering, (self.slider.cell as? SourceCell)?.isTracking != true else { return }
      self.apply(snapshot)
      self.refreshPowerButton()
    }
  }

  private func apply(_ snapshot: InputSourceSnapshot) {
    self.snapshot = snapshot
    (self.slider.cell as? SourceCell)?.sourceNames = snapshot.sources.map { $0.name }
    self.slider.numberOfTickMarks = snapshot.sources.count
    self.slider.isEnabled = snapshot.sources.count > 1 && snapshot.selectedIndex != nil && !self.powering && !self.display.dpmsOffRequested
    self.slider.alphaValue = snapshot.selectedIndex == nil || self.display.dpmsOffRequested ? 0.35 : 1
    if let index = snapshot.selectedIndex {
      self.slider.doubleValue = snapshot.sources.count > 1 ? Double(index) / Double(snapshot.sources.count - 1) : 0
      self.slider.setAccessibilityValueDescription(snapshot.sources[index].name)
    } else {
      self.slider.setAccessibilityValueDescription(NSLocalizedString("Source unavailable", comment: "Source slider"))
    }
    self.slider.toolTip = snapshot.sources.map { $0.name }.joined(separator: " • ")
    self.slider.needsDisplay = true
    self.updatePowerButton()
  }

  private func refreshPowerButton() {
    self.display.refreshPowerMode { [weak self] in
      guard let self = self, !self.powering, !self.switching else { return }
      self.apply(self.snapshot)
    }
  }

  private func updatePowerButton() {
    self.powerButton.isEnabled = !self.powering && !self.switching && (self.display.reportedPowerMode != nil || self.display.dpmsOffRequested)
    self.powerButton.state = self.display.dpmsOffRequested ? .on : .off
    let action = self.display.dpmsOffRequested ? NSLocalizedString("Wake display (DPMS)", comment: "Display power button") : NSLocalizedString("Sleep display (DPMS)", comment: "Display power button")
    self.powerButton.toolTip = action
    self.powerButton.setAccessibilityLabel(action + " — " + self.display.name)
    self.powerButton.needsDisplay = true
  }

  @objc private func togglePower(_ sender: NSButton) {
    guard !self.powering, !self.switching else { return }
    let awake = self.display.dpmsOffRequested
    self.powering = true
    self.apply(self.snapshot)
    self.display.setDisplayPower(awake: awake) { [weak self] result in
      guard let self = self else { return }
      self.powering = false
      self.apply(self.snapshot)
      let confirmed = result.reportedMode.map { awake ? $0 == 1 : $0 != 1 } ?? false
      if !result.sent || !confirmed {
        self.powerButton.toolTip = NSLocalizedString("Power change not confirmed; try again or use the monitor power button.", comment: "Display power button")
      }
    }
  }

  @objc private func sourceChanged(_ slider: NSSlider) {
    guard !self.switching, self.snapshot.sources.count > 1 else { return }
    let index = min(self.snapshot.sources.count - 1, max(0, Int((slider.doubleValue * Double(self.snapshot.sources.count - 1)).rounded())))
    let source = self.snapshot.sources[index]
    slider.doubleValue = Double(index) / Double(self.snapshot.sources.count - 1)
    guard source.code != self.snapshot.current else { return }
    self.switching = true
    self.updatePowerButton()
    slider.isEnabled = false
    slider.setAccessibilityValueDescription(NSLocalizedString("Switching to", comment: "Source slider") + " " + source.name)
    self.display.switchInput(to: source.code) { [weak self] result in
      guard let self = self else { return }
      self.switching = false
      switch result {
      case let .confirmed(actual):
        self.apply(InputSourceSnapshot(sources: self.snapshot.sources, current: actual))
      case let .unconfirmed(actual):
        self.apply(InputSourceSnapshot(sources: self.snapshot.sources, current: actual))
        self.slider.toolTip = NSLocalizedString("Source switch not confirmed", comment: "Source slider")
      }
    }
  }
}
