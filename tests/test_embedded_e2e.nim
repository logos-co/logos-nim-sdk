## End-to-end: an embedded Logos core, a real module in its own host process,
## and every consumer call going through `lp_*`.
##
## This is the shape the Nim SDK has always been used in — the process embeds
## `liblogos_core` and loads a module — so it is the test that proves the port
## did not lose anything. What changed is the bottom half of every call:
## `logos_core_call_plugin_method_async` / `logos_core_register_event_listener`
## are gone (removed from liblogos_core by the protocol extraction) and the
## same work now goes over `lp_client_create` / `lp_invoke` / `lp_invoke_async`
## / `lp_subscribe`.
##
## No Qt event loop runs in this process. Both modules are put on a PLAIN tcp
## transport before they load, which is the whole point of being
## protocol-native: the Qt-affine default would require one.
##
## Environment (set by the nix check):
##   LOGOS_CORE_LIB      path to liblogos_core.{dylib,so}
##   LOGOS_MODULES_DIR   ':'-separated module dirs (<dir>/<name>/<name>_plugin.*)
##   LOGOS_HOST_PATH     path to the logos_host binary
##   LOGOS_PROTOCOL_LIB  path to the SHARED liblogos_protocol.{dylib,so}

import std/[json, os, times, strutils, unittest]

import ../logos_api

const ModuleName = "test_basic_module"

let coreLib = getEnv("LOGOS_CORE_LIB")
let modulesDirs = getEnv("LOGOS_MODULES_DIR")

if coreLib.len == 0 or modulesDirs.len == 0:
  echo "SKIP: LOGOS_CORE_LIB / LOGOS_MODULES_DIR not set"
  quit(0)

# Ports are picked high and per-run to keep parallel checks from colliding.
let portBase = 17000 + int(getCurrentProcessId() mod 4000) * 2
let modulePort = portBase
let capabilityPort = portBase + 1

proc pump(api: LogosAPI, ms: int) =
  let deadline = epochTime() + float(ms) / 1000.0
  while epochTime() < deadline:
    api.processEventsTick()
    sleep(10)

let dirs = modulesDirs.split(':')
let api = newLogosAPI(libPath = coreLib, modulesDir = dirs[0],
                      autoInit = true, originModule = "nim_e2e_consumer")
for d in dirs[1 .. ^1]: api.addModulesDir(d)

# Both transports must be registered BEFORE the module that uses them loads;
# capability_module loads inside start().
api.setModuleTransport("capability_module", tcpTransport("127.0.0.1", capabilityPort))
api.setModuleTransport(ModuleName, tcpTransport("127.0.0.1", modulePort))

doAssert api.start()
doAssert api.loadModule(ModuleName), "core could not load " & ModuleName
doAssert ModuleName in api.getLoadedModules()
api.pump(500)

let m = api.module(ModuleName)

suite "consumer calls over lp_invoke":

  test "a string round-trips":
    check m.invoke("echo", %*["hello from nim"]).getStr() == "hello from nim"

  test "integers survive the JSON-in-strings data model":
    check m.invoke("addInts", %*[20, 22]).getInt() == 42
    check m.invoke("echoInt", %*[-7]).getInt() == -7

  test "booleans are booleans, not strings":
    check m.invoke("returnTrue", %*[]).getBool()
    check m.invoke("returnFalse", %*[]).getBool() == false
    check m.invoke("isPositive", %*[5]).getBool()
    check m.invoke("isPositive", %*[-5]).getBool() == false

  test "every arity from zero to five arrives intact":
    check m.invoke("noArgs", %*[]).getStr().len > 0
    check m.invoke("oneArg", %*["a"]).getStr().contains("a")
    check m.invoke("twoArgs", %*["a", 2]).getStr().contains("2")
    check m.invoke("threeArgs", %*["a", 2, true]).getStr().len > 0
    check m.invoke("fourArgs", %*["a", 2, true, "d"]).getStr().contains("d")
    check m.invoke("fiveArgs", %*["a", 2, true, "d", 5]).getStr().contains("5")

  test "JSON-array and variant returns decode as arrays and objects":
    check $m.invoke("returnJsonArray", %*[]) == "[1,2,3]"
    check $m.invoke("makeJsonArray", %*["x", "y"]) == """["x","y"]"""
    let vl = m.invoke("returnVariantList", %*[])
    check vl.kind == JArray
    check vl.len == 3
    let vm = m.invoke("returnVariantMap", %*[])
    check vm.kind == JObject
    check vm["number"].getInt() == 7

  test "a string LIST argument arrives intact":
    check m.invoke("joinStrings", %*[["p", "q"]]).getStr() == "p, q"

  test "KNOWN DEFECT: a string-list RETURN is flattened by the plain codec":
    # Not a defect of this SDK, and not of the JSON model — pinned here so it
    # is visible and so the day it is fixed this test fails loudly instead of
    # the behaviour changing unnoticed.
    #
    # logos-protocol's plain (tcp / tcp_ssl) codec, qvariant_rpc_value.cpp,
    # switches on QMetaType and has cases for QVariantList / QVariantMap but
    # NONE for QMetaType::QStringList, so a QStringList falls through to the
    # `default:` "best-effort fallback: stringify" arm. Qt's QStringList ->
    # QString conversion yields the single element for a 1-element list and an
    # EMPTY string for anything longer — so every std::vector<std::string>
    # return over a plain transport arrives as "". (qvariantToNlohmann, the
    # layer above, handles QStringList correctly; the loss is on the wire.)
    check m.invoke("splitString", %*["a,b,c"]).getStr() == ""
    check m.invoke("returnStringList", %*[]).getStr() == ""

  test "a LogosResult decodes as an object, success and failure differing":
    let ok = m.invoke("validateInput", %*["abc"])
    let bad = m.invoke("validateInput", %*[""])
    check ok.kind == JObject
    check bad.kind == JObject
    check $ok != $bad

  test "bytes cross the ABI in the _bytes envelope":
    # byteArraySize counts the bytes it was handed, so a wrong encoding shows
    # up as a wrong number rather than as an error.
    check m.invoke("byteArraySize", %*[bytesArg("abcde")]).getInt() == 5
    check m.invoke("byteArraySize", %*[bytesArg("")]).getInt() == 0

  test "tryInvoke reports instead of raising":
    let o = m.tryInvoke("echo", %*["x"])
    check o.ok
    check o.value.getStr() == "x"

suite "consumer calls over lp_invoke_async":

  test "the legacy async facade still delivers, with its old message shape":
    var got = ""
    var fired = false
    api.callPluginMethodAsync(ModuleName, "echo",
                              """[{"name":"a","value":"async hi","type":"string"}]""",
                              proc (success: bool, message: string) =
                                got = message
                                fired = success)
    api.pump(5000)
    check fired
    # A string result arrives UNQUOTED, as it always did.
    check got == "async hi"

  test "PluginProxy.call keeps its old shape":
    var got = ""
    m.call("echo", "via proxy", proc (success: bool, message: string) =
      if success: got = message)
    api.pump(5000)
    check got == "via proxy"

suite "events over lp_subscribe":

  test "a subscription armed against a live module receives its emit":
    var payloads: seq[JsonNode] = @[]
    let c = api.client(ModuleName)
    let sub = c.subscribe("testEvent", proc (name: string, data: JsonNode) =
      payloads.add data)
    api.pump(500)
    # Nothing pending means it armed rather than being merely accepted.
    check $c.pendingSubscriptions() == "[]"

    discard m.invoke("emitTestEvent", %*["ping-1"])
    api.pump(3000)
    check payloads.len >= 1
    check $payloads[0] == """["ping-1"]"""
    sub.cancel()

  test "a multi-argument event arrives as a JSON array of its arguments":
    var seen: seq[JsonNode] = @[]
    let sub = m.subscribe("multiArgEvent", proc (name: string, data: JsonNode) =
      seen.add data)
    api.pump(500)
    discard m.invoke("emitMultiArgEvent", %*["widgets", 3])
    api.pump(3000)
    check seen.len >= 1
    check seen[0].kind == JArray
    check seen[0].len == 2
    check seen[0][0].getStr() == "widgets"
    check seen[0][1].getInt() == 3
    sub.cancel()

  test "a cancelled subscription stops delivering":
    var count = 0
    let sub = m.subscribe("testEvent", proc (name: string, data: JsonNode) =
      inc count)
    api.pump(500)
    discard m.invoke("emitTestEvent", %*["before"])
    api.pump(2000)
    let afterFirst = count
    check afterFirst >= 1
    sub.cancel()
    discard m.invoke("emitTestEvent", %*["after"])
    api.pump(2000)
    check count == afterFirst

  test "the legacy event facade still delivers":
    var messages: seq[string] = @[]
    api.registerEventListener(ModuleName, "testEvent",
                              proc (success: bool, message: string) =
                                if success: messages.add message)
    api.pump(500)
    discard m.invoke("emitTestEvent", %*["legacy"])
    api.pump(3000)
    check messages.len >= 1
    check """["legacy"]""" in messages

suite "introspection":

  test "lp_get_methods sees the module's surface":
    let methods = api.client(ModuleName).getMethods()
    check methods.kind == JArray
    check methods.len > 0
    var names: seq[string] = @[]
    for entry in methods:
      if entry.kind == JObject and entry.hasKey("name"):
        names.add entry["name"].getStr()
    check "echo" in names
    check "addInts" in names

suite "runtime half still works against today's core":

  test "the core reports what it knows and what it loaded":
    check ModuleName in api.getKnownModules()
    check ModuleName in api.getLoadedModules()

  test "modules info is structured JSON naming the module":
    let info = api.getModulesInfo()
    check info.kind == JArray
    var found = false
    for e in info:
      if e.kind == JObject and e.hasKey("name") and
         e["name"].getStr() == ModuleName:
        found = true
        check e["loaded"].getBool()
    check found

  test "loadModule is idempotent":
    check api.loadModule(ModuleName)

api.cleanup()
