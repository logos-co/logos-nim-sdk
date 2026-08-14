## Hermetic consumer-surface tests.
##
## These need nothing but the shared logos-protocol library — no liblogos_core,
## no module, no Qt event loop. They pin the parts of the port that are cheap
## to get subtly wrong: symbol binding, the JSON-in-strings data model, the
## canonical error object, ownership of returned strings, and the "held until
## the module appears" subscription contract.

import std/[json, strutils, sequtils, unittest]

import ../logos_client
import ../logos_protocol as lp

# A port nothing listens on: the target is reachable-in-principle but absent,
# which is the failure the ABI reports as a canonical error object.
const DeadPort = 59777
const ShortTimeout = 2000

suite "protocol binding":

  test "the shared library loads and reports a version":
    loadProtocol()
    check isProtocolLoaded()
    check protocolLibPath().len > 0
    let v = protocolVersion()
    let parts = v.split('.')
    check parts.len == 3
    for p in parts:
      check p.len > 0
      check p.allCharsInSet({'0' .. '9'})
    # Same number, reported two ways — a mismatch means the two entry points
    # were bound out of different images.
    check protocolAbiMajor() == parseInt(parts[0])

  test "process mode round-trips and rejects nonsense":
    let original = getMode()
    check original.len > 0
    check setMode("mock")
    check getMode() == "mock"
    check setMode("local")
    check getMode() == "local"
    check(not setMode("definitely-not-a-mode"))
    check getMode() == "local" # a refused set must not change anything
    check setMode(original)
    check getMode() == original

  test "default transport parses good JSON and refuses bad":
    check setDefaultTransport("""{"protocol":"local"}""")
    check(not setDefaultTransport("{ this is not json"))

suite "transport helpers":

  test "tcp transport JSON has the documented shape":
    let t = parseJson(tcpTransport("10.0.0.5", 6001))
    check t["protocol"].getStr() == "tcp"
    check t["host"].getStr() == "10.0.0.5"
    check t["port"].getInt() == 6001
    check t["codec"].getStr() == "json"

  test "tcp_ssl transport carries only the files it was given":
    let t = parseJson(tcpSslTransport("h", 443, caFile = "/ca.pem"))
    check t["protocol"].getStr() == "tcp_ssl"
    check t["verify_peer"].getBool()
    check t["ca_file"].getStr() == "/ca.pem"
    check(not t.hasKey("cert_file"))

  test "the library accepts every transport this SDK can emit":
    check setDefaultTransport(localTransport())
    check setDefaultTransport(tcpTransport("127.0.0.1", 6001))
    check setDefaultTransport(tcpTransport("127.0.0.1", 6001, codec = "cbor"))
    check setDefaultTransport(tcpSslTransport("127.0.0.1", 6443))
    # ... and put the process default back.
    check setDefaultTransport(localTransport())

suite "bytes envelope":

  test "arbitrary bytes survive the {\"_bytes\": base64url} envelope":
    for payload in ["", "hello", "\x00\x01\xfe\xff", "~~~???>>>"]:
      let n = bytesArg(payload)
      check isBytes(n)
      check bytesValue(n) == payload
    # base64url, so never a '+' or '/' even for input that produces them.
    let tricky = bytesArg("\xfb\xff\xbf")
    check '+' notin tricky["_bytes"].getStr()
    check '/' notin tricky["_bytes"].getStr()

  test "a plain object is not mistaken for a bytes envelope":
    check(not isBytes(%*{"_bytes": "a", "other": 1}))
    check(not isBytes(%*{"x": 1}))
    check(not isBytes(newJString("_bytes")))

suite "legacy parameter shape":

  test "typed strings are coerced the way the C facade coerces them":
    let args = legacyParamsToArgs("""[
      {"name":"a","value":"42","type":"int"},
      {"name":"b","value":"3.5","type":"double"},
      {"name":"c","value":"true","type":"bool"},
      {"name":"d","value":"plain","type":"string"}
    ]""")
    check args.kind == JArray
    check args.len == 4
    check args[0].kind == JInt and args[0].getInt() == 42
    check args[1].kind == JFloat and args[1].getFloat() == 3.5
    check args[2].kind == JBool and args[2].getBool()
    check args[3].getStr() == "plain"

  test "an uncoercible typed value fails fast instead of going on the wire":
    expect ValueError:
      discard legacyParamsToArgs("""[{"name":"a","value":"12x","type":"int"}]""")

  test "malformed JSON fails fast":
    expect ValueError:
      discard legacyParamsToArgs("[{")

  test "a plain args array passes through untouched":
    let args = legacyParamsToArgs("""[1, "two", {"k":3}, null]""")
    check $args == """[1,"two",{"k":3},null]"""

  test "an empty spec is an empty argument list":
    check $legacyParamsToArgs("") == "[]"
    check $legacyParamsToArgs("   ") == "[]"

suite "consumer client against an absent module":

  setup:
    loadProtocol()
    let transport = tcpTransport("127.0.0.1", DeadPort)

  test "a client is created even though nothing is listening":
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    check(not m.isClosed())
    check m.target == "ghost_module"
    check m.origin == "nim_test_consumer"
    m.close()
    check m.isClosed()
    m.close() # idempotent

  test "an unreachable target reports the canonical error object":
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    defer: m.close()
    let o = m.tryInvoke("anything", %*[1, 2], ShortTimeout)
    check(not o.ok)
    # code/message come from {"code","message","origin"} — decoding them is
    # the whole point of the error path.
    check o.code.len > 0
    check o.code != "unknown"
    check o.message.len > 0

  test "invoke raises a LogosCallError carrying the code":
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    defer: m.close()
    var raised = false
    try:
      discard m.invoke("anything", %*[], ShortTimeout)
    except LogosCallError as e:
      raised = true
      check e.code.len > 0
      check e.origin.len > 0
      check "ghost_module" in e.msg
    check raised

  test "a subscription to an absent module is held, not refused":
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    defer: m.close()
    var seen = 0
    let s = m.subscribe("someEvent", proc (name: string, payload: JsonNode) =
      inc seen)
    check s != nil
    # Accepted-but-not-armed is exactly what lp_pending_subscriptions reports.
    let pending = m.pendingSubscriptions()
    check pending.kind == JArray
    check "ghost_module::someEvent" in pending.mapIt(it.getStr())
    # Nothing can have been delivered.
    check poll() == 0
    check seen == 0
    s.cancel()

  test "an async call to an absent module always reaches the handler":
    # The handler must fire even though the library's async capability
    # handshake drops its continuation when capability_module cannot be
    # acquired — poll()'s watchdog answers for it. A consumer that hangs
    # forever is the failure this pins shut.
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    defer: m.close()
    var got: CallOutcome
    var fired = false
    m.invokeAsync("anything", %*[], ShortTimeout, proc (o: CallOutcome) =
      got = o
      fired = true)
    # Nothing is delivered until this thread pumps.
    check poll() == 0
    check(not fired)
    discard waitFor(ShortTimeout + asyncWatchdogGraceMs + 3000,
                    proc (): bool = fired)
    check fired
    check(not got.ok)
    check got.code.len > 0
    check got.origin == "ghost_module"

  test "using a closed client raises rather than crashing":
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    m.close()
    expect LogosProtocolError:
      discard m.tryInvoke("anything", %*[], ShortTimeout)
    expect LogosProtocolError:
      discard m.pendingSubscriptions()

  test "queued payloads for a closed client are dropped, not delivered":
    let m = newModuleClient("ghost_module", "nim_test_consumer", transport,
                            transport)
    var fired = false
    m.invokeAsync("anything", %*[], 300, proc (o: CallOutcome) =
      fired = true)
    m.close()
    discard pollFor(1500)
    check(not fired)

  test "LogosClient caches one client per target":
    let l = newLogosClient("nim_test_consumer", transport)
    defer: l.close()
    let a = l.module("ghost_module")
    let b = l.module("ghost_module")
    check a == b
    check l.module("other_ghost") != a

suite "token store":

  test "a saved token comes back and an unknown one is empty":
    loadProtocol()
    check tokenGet("nim_sdk_never_saved_this") == ""
    check tokenSave("nim_sdk_token_probe", "t0k3n")
    check tokenGet("nim_sdk_token_probe") == "t0k3n"
