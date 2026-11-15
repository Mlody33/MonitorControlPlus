import Foundation

@main
struct InputSourceTests {
  static func reply(_ payload: [UInt8], offset: UInt16) -> [UInt8] {
    var bytes: [UInt8] = [0x6E, UInt8(0x80 | (payload.count + 3)), 0xE3, UInt8(offset >> 8), UInt8(offset & 255)] + payload
    bytes.append(bytes.reduce(UInt8(0x50), ^))
    return bytes + Array(repeating: 0, count: 38 - bytes.count)
  }

  static func main() {
    let actual = "(prot(monitor)model(ThinkVision P27h-20)vcp(10 12 14(01 05 60) 60(0F 11 31) C6(02 01 E3))mccs_ver(2.2))"
    assert(DDCInputCapabilities.parse(actual) == [0x0F, 0x11, 0x31])
    assert(DDCInputCapabilities.parse("(vcp(14(60 11 31) 10 12))") == nil)
    assert(DDCInputCapabilities.parse("(VCP(60(0f 11 11 31)))") == [0x0F, 0x11, 0x31])
    for malformed in ["", "(vcp(60))", "(vcp(60()))", "(vcp(60(0F XX)))", "(vcp(60(0000)))"] {
      assert(DDCInputCapabilities.parse(malformed) == nil, malformed)
    }
    let encoded = Array(actual.utf8) + [0]
    var requests = 0
    let sources = DDCInputCapabilities.read { request, count in
      assert(count == 38 && request.count == 6)
      assert(request.prefix(5).reduce(UInt8(0x6E), ^) == request[5])
      let offset = UInt16(request[3]) << 8 | UInt16(request[4])
      requests += 1
      return self.reply(Array(encoded.dropFirst(Int(offset)).prefix(32)), offset: offset)
    }
    assert(sources == [0x0F, 0x11, 0x31] && requests > 1)
    var attempts = 0
    assert(DDCInputCapabilities.read { _, _ in attempts += 1; return nil } == nil)
    assert(attempts == 3)
    var invalid = self.reply([65], offset: 0)
    invalid[6] ^= 1
    assert(DDCInputCapabilities.decodeReply(invalid, offset: 0) == nil)
    assert(DDCInputCapabilities.decodeReply(self.reply([65], offset: 1), offset: 0) == nil)
    assert(DDCInputCapabilities.decodeReply([0x6E, 0xFF], offset: 0) == nil)
    let options = [UInt16(0x0F), 0x11, 0x31].map { DDCInputSource(code: $0, displayName: "P27h-20 (1)") }
    assert(options.map { $0.name } == ["DP", "HDMI", "USB-C"])
    assert(InputSourceSnapshot(sources: options, current: 0x31).selectedIndex == 2)
    assert(InputSourceSnapshot(sources: options, current: 0x11).selectedIndex == 1)
    assert(InputSourceSnapshot(sources: options, current: nil).selectedIndex == nil)
    assert(InputSourceSnapshot(sources: options, current: 0x7F).selectedIndex == nil)
    assert(DDCInputSource(code: 0x31, displayName: "Other display").name == "0x31")
    print("PASS: capabilities parsing/framing/retries, unknown sources, source labels, active source index")
  }
}
