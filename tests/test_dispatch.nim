## The dispatch profile: route a named call with JSON arguments to a Nim proc,
## inline, checking arity and types on the way in.
import std/[unittest, json, tables]
import ../sdk/dispatch_macro

var lastTopic = ""

proc subscribe(topic: string): bool {.dispatchMethod.} =
  lastTopic = topic
  return true

proc addUp(a, b: int): int {.dispatchMethod.} =
  return a + b

proc echoBytes(blob: seq[byte]): seq[byte] {.dispatchMethod.} =
  return blob

proc notify(msg: string) {.dispatchMethod.} =
  lastTopic = "notified:" & msg

proc deliveryProgress(opId: string, state: string): string {.dispatchMethod.} =
  return opId & ":" & state

proc sendIt(topic: string): string {.dispatchAs: "send".} =
  return "sent " & topic

let table = dispatchTableFor()

suite "routing":
  test "a call reaches its proc and the result comes back as JSON":
    let r = table.dispatch("subscribe", %*["chat"])
    check r.ok
    check r.value == %true
    check lastTopic == "chat"

  test "multiple parameters, in order":
    check table.dispatch("add_up", %*[2, 3]).value == %5

  test "a proc with no return answers null":
    let r = table.dispatch("notify", %*["hi"])
    check r.ok and r.value.kind == JNull
    check lastTopic == "notified:hi"

  test "the wire name is snake_case":
    check table.hasKey("delivery_progress")
    check not table.hasKey("deliveryProgress")
    check table.dispatch("delivery_progress", %*["op-1", "queued"]).value ==
      %"op-1:queued"

  test "an explicit wire name overrides the derived one":
    check table.hasKey("send")
    check not table.hasKey("send_it")
    check table.dispatch("send", %*["chat"]).value == %"sent chat"

suite "rejection":
  test "an unknown method is reported, not raised":
    let r = table.dispatch("nope", %*[])
    check not r.ok
    check r.err.kind == deUnknownMethod
    check r.err.meth == "nope"

  test "wrong arity names both counts":
    let r = table.dispatch("add_up", %*[1])
    check not r.ok
    check r.err.kind == deArity
    check r.err.wantArity == 2 and r.err.gotArity == 1

  test "a wrong argument type names the position and both types":
    let r = table.dispatch("subscribe", %*[42])
    check not r.ok
    check r.err.kind == deArgType
    check r.err.argIndex == 0
    check r.err.wantType == "string" and r.err.gotType == "number"

suite "bytes go through the Logos convention":
  test "encoded out as the tagged object, never an array of numbers":
    # `[0x00,0x7f,0x80,0xff]` <-> "AH-A_w" is one of the vectors pinned across
    # all three languages. An array of numbers here is the bug class this
    # convention exists to prevent: it round-trips in Nim and decodes as
    # something else everywhere else.
    let r = table.dispatch("echo_bytes", %*[{"_bytes": "AH-A_w"}])
    check r.ok
    check r.value == %*{"_bytes": "AH-A_w"}

  test "the lenient shapes the other scaffolds accept are accepted here":
    let r = table.dispatch("echo_bytes", %*[[0, 127, 128, 255]])
    check r.ok
    check r.value == %*{"_bytes": "AH-A_w"}

suite "the names are available for introspection":
  test "declaration order is preserved":
    let names = dispatchMethodNames()
    check names == @["subscribe", "add_up", "echo_bytes", "notify",
                     "delivery_progress", "send"]

suite "shape metadata, for an ABI to build a manifest from":
  test "parameter names, Nim types, return type and doc are captured":
    let meta = dispatchMethodMeta()
    check meta.len == 6

    let sub = meta[0]
    check sub.wireName == "subscribe"
    check sub.procName == "subscribe"
    check sub.params.len == 1
    check sub.params[0].name == "topic"
    check sub.params[0].nimType == "string"
    check sub.returnType == "bool"

    # grouped parameters (`a, b: int`) are expanded one per name
    let add = meta[1]
    check add.params.len == 2
    check add.params[0].name == "a" and add.params[1].name == "b"
    check add.params[0].nimType == "int"

    # a proc with no return reports an empty type, not "void"
    check meta[3].returnType == ""

    # the explicit wire name is recorded, and the Nim name kept beside it
    check meta[5].wireName == "send" and meta[5].procName == "sendIt"

  test "the doc comment's first line comes through":
    # `echoBytes` has none; the ones that do are in the SDK's tests.
    check dispatchMethodMeta()[2].doc == ""
