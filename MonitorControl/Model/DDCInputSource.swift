// Copyright © MonitorControl contributors.

import Foundation

struct DDCInputSource: Equatable {
  let code: UInt16
  let name: String

  init(code: UInt16, displayName: String) {
    self.code = code
    switch code {
    case 0x01: self.name = "VGA 1"
    case 0x02: self.name = "VGA 2"
    case 0x03: self.name = "DVI 1"
    case 0x04: self.name = "DVI 2"
    case 0x0F: self.name = "DP"
    case 0x10: self.name = "DP 2"
    case 0x11: self.name = "HDMI"
    case 0x12: self.name = "HDMI 2"
    case 0x31 where displayName.lowercased().contains("p27h-20"): self.name = "USB-C"
    default: self.name = String(format: "0x%02X", code)
    }
  }
}

struct InputSourceSnapshot {
  let sources: [DDCInputSource]
  let current: UInt16?

  var selectedIndex: Int? {
    guard let current = self.current else { return nil }
    return self.sources.firstIndex { $0.code == current }
  }
}

enum InputSwitchResult {
  case confirmed(UInt16)
  case unconfirmed(UInt16?)
}

/// MCCS capabilities enumerate supported ports, not connected cables.
/// Shared framing/parser code keeps both DDC transports consistent.
enum DDCInputCapabilities {
  static func parse(_ capabilities: String) -> [UInt16]? {
    let bytes = Array(capabilities.utf8)
    let pattern = Array("vcp(".utf8)
    guard let start = bytes.indices.first(where: { index in
      index + pattern.count <= bytes.count && Array(bytes[index ..< index + pattern.count]).map { $0 | 0x20 } == pattern
    }) else { return nil }
    var cursor = start + pattern.count
    func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
    while cursor < bytes.count, bytes[cursor] != 41 {
      while cursor < bytes.count, whitespace(bytes[cursor]) { cursor += 1 }
      let tokenStart = cursor
      while cursor < bytes.count, !whitespace(bytes[cursor]), bytes[cursor] != 40, bytes[cursor] != 41 { cursor += 1 }
      guard cursor > tokenStart else { return nil }
      let token = String(decoding: bytes[tokenStart ..< cursor], as: UTF8.self)
      while cursor < bytes.count, whitespace(bytes[cursor]) { cursor += 1 }
      if cursor < bytes.count, bytes[cursor] == 40 {
        cursor += 1
        let valuesStart = cursor
        var depth = 1
        while cursor < bytes.count, depth > 0 {
          if bytes[cursor] == 40 { depth += 1 }
          if bytes[cursor] == 41 { depth -= 1 }
          if depth > 0 { cursor += 1 }
        }
        guard depth == 0 else { return nil }
        if UInt8(token, radix: 16) == Command.inputSelect.rawValue {
          let values = String(decoding: bytes[valuesStart ..< cursor], as: UTF8.self).split { $0.isWhitespace }
          var result: [UInt16] = []
          for value in values {
            guard let code = UInt16(value, radix: 16), code > 0 else { return nil }
            if !result.contains(code) { result.append(code) }
          }
          return result.isEmpty ? nil : result
        }
        cursor += 1
      }
    }
    return nil
  }

  static func decodeReply(_ reply: [UInt8], offset: UInt16) -> [UInt8]? {
    guard reply.count >= 6, reply[0] == 0x6E, reply[1] & 0x80 != 0 else { return nil }
    let length = Int(reply[1] & 0x7F)
    guard length >= 3, length + 3 <= reply.count, reply[2] == 0xE3,
          UInt16(reply[3]) << 8 | UInt16(reply[4]) == offset,
          reply.prefix(length + 2).reduce(UInt8(0x50), ^) == reply[length + 2]
    else { return nil }
    return Array(reply[5 ..< length + 2])
  }

  static func read(exchange: ([UInt8], Int) -> [UInt8]?) -> [UInt16]? {
    var result: [UInt8] = []
    for _ in 0 ..< 128 {
      guard result.count < 4096 else { return nil }
      let offset = UInt16(result.count)
      var request: [UInt8] = [0x51, 0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 255)]
      request.append(request.reduce(UInt8(0x6E), ^))
      var chunk: [UInt8]?
      for _ in 0 ..< 3 {
        if let reply = exchange(request, 38), let decoded = self.decodeReply(reply, offset: offset) {
          chunk = decoded
          break
        }
      }
      guard let bytes = chunk else { return nil }
      if let end = bytes.firstIndex(of: 0) {
        result.append(contentsOf: bytes.prefix(end))
        return String(bytes: result, encoding: .ascii).flatMap(self.parse)
      }
      if bytes.isEmpty {
        return String(bytes: result, encoding: .ascii).flatMap(self.parse)
      }
      result.append(contentsOf: bytes)
    }
    return nil
  }
}
