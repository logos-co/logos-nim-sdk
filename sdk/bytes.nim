## Binary data across the lp_* wire.
##
## The Logos data model is JSON-in-strings, so bytes cannot travel as
## themselves. The canonical form is a tagged object:
##
##     {"_bytes": "<base64url, unpadded>"}
##
## Encoding is exact and unpadded, because a stray '=' is precisely how two
## implementations of this stop agreeing. Decoding is deliberately lenient --
## it accepts four other shapes -- so that Nim, Rust and C++ answer a given
## argument identically rather than one of them rejecting what the others take.
import std/json

const B64* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  ## URL-safe alphabet: '-' is 62 and '_' is 63.

func encodeB64Url*(bytes: openArray[byte]): string =
  ## Never padded. A 1-byte tail emits 2 characters, a 2-byte tail 3.
  var s = ""
  var i = 0
  while i < bytes.len:
    let b0 = uint32(bytes[i])
    let b1 = if i + 1 < bytes.len: uint32(bytes[i + 1]) else: 0'u32
    let b2 = if i + 2 < bytes.len: uint32(bytes[i + 2]) else: 0'u32
    let n = (b0 shl 16) or (b1 shl 8) or b2
    let tail = min(bytes.len - i, 3)
    for k in 0 .. tail:
      s.add(B64[int((n shr (18 - 6 * k)) and 63)])
    i += 3
  return s

func decodeB64Url*(s: string): seq[byte] =
  ## Tolerates padding on input: a hand-rolled or CLI caller may well add it, and
  ## refusing would make this stricter than the encoders it must interoperate
  ## with. Characters outside the alphabet are skipped.
  var acc: uint32 = 0
  var bits = 0
  var outBytes: seq[byte] = @[]
  for ch in s:
    if ch == '=': continue
    let idx = B64.find(ch)
    if idx < 0: continue
    acc = (acc shl 6) or uint32(idx)
    bits += 6
    if bits >= 8:
      bits -= 8
      outBytes.add(byte((acc shr bits) and 0xff))
  return outBytes

func toLogosBytes*(b: openArray[byte]): JsonNode {.raises: [].} =
  ## Always the canonical form. Never emit one of the lenient shapes.
  return %*{"_bytes": encodeB64Url(b)}

func isLogosBytes*(n: JsonNode): bool {.raises: [].} =
  return n.kind == JObject and n.len == 1 and n.hasKey("_bytes") and
         n.getOrDefault("_bytes").kind == JString

func fromLogosBytes*(n: JsonNode): seq[byte] {.raises: [].} =
  ## Canonical form first, then the four lenient shapes logos-protocol's
  ## `bytesFromJsonLenient` accepts:
  ##   a bare string  -> its UTF-8 bytes   (a QString reaching a bstr parameter)
  ##   a number       -> its decimal text  (QVariant(int) -> QByteArray parity)
  ##   an array       -> those bytes, masked; non-integer elements skipped
  ## Anything else -- bool, null, an untagged object -- yields nothing, and the
  ## caller reports "expected bytes at argN".
  if isLogosBytes(n):
    # `[]` on a JsonNode raises KeyError; isLogosBytes has already established
    # the key is there, and getOrDefault keeps that provable to the compiler.
    return decodeB64Url(n.getOrDefault("_bytes").getStr())
  case n.kind
  of JString: return cast[seq[byte]](n.getStr())
  of JInt: return cast[seq[byte]]($n.getInt())
  of JArray:
    var s: seq[byte] = @[]
    for e in n:
      if e.kind == JInt: s.add(byte(e.getInt() and 0xff))
    return s
  else: return @[]
