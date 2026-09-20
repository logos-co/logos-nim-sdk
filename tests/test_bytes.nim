## Cross-language conformance for the {"_bytes":...} convention.
##
## These vectors are the contract with logos-rust-sdk's src/bytes.rs. If this
## file goes red, Nim and Rust have diverged and a payload that crosses between
## them is being corrupted, not rejected -- which is the expensive kind of bug.
import std/[unittest, json]
import ../sdk/bytes

suite "base64url":
  test "pinned cross-language vectors":
    check encodeB64Url([0x00'u8, 0x7f, 0x80, 0xff]) == "AH-A_w"
    check encodeB64Url(cast[seq[byte]]("x\0y")) == "eAB5"
    check encodeB64Url(newSeq[byte]()) == ""

  test "never padded":
    for n in 1 .. 8:
      var b = newSeq[byte](n)
      check '=' notin encodeB64Url(b)

  test "padding is tolerated on input":
    check decodeB64Url("AH-A_w==") == @[0x00'u8, 0x7f, 0x80, 0xff]
    check decodeB64Url("AH-A_w") == @[0x00'u8, 0x7f, 0x80, 0xff]

  test "every byte value survives a round trip":
    var all = newSeq[byte](256)
    for i in 0 .. 255: all[i] = byte(i)
    check decodeB64Url(encodeB64Url(all)) == all

suite "the tagged object":
  test "canonical form round-trips":
    let n = toLogosBytes([1'u8, 2, 3])
    check n == %*{"_bytes": "AQID"}
    check fromLogosBytes(n) == @[1'u8, 2, 3]

  test "an extra key is not a bytes object":
    check not isLogosBytes(%*{"_bytes": "AQID", "x": 1})
    check not isLogosBytes(%*{"_bytes": 42})

suite "lenient decode, for parity with Rust and C++":
  test "a bare string is its UTF-8 bytes":
    check fromLogosBytes(%"hi") == @[byte('h'), byte('i')]
  test "a number is its decimal text":
    check fromLogosBytes(%12) == @[byte('1'), byte('2')]
  test "an array is those bytes, masked":
    check fromLogosBytes(%*[1, 2, 511]) == @[1'u8, 2, 255]
  test "anything else yields nothing":
    check fromLogosBytes(%true).len == 0
    check fromLogosBytes(newJNull()).len == 0
    check fromLogosBytes(%*{"nope": 1}).len == 0
