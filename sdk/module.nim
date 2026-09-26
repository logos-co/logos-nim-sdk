## Being a Logos module: the seven C exports, over the dispatch profile.
##
## A module writes ordinary Nim procs and one terminal call:
##
##     import logos_sdk
##
##     proc subscribe(topic: string): bool {.dispatchMethod.} = ...
##     proc send(topic: string, blob: seq[byte]): string {.dispatchMethod.} = ...
##
##     logosModule("lockbox_transport", "0.1.0",
##                 contract = staticRead("../contracts/lockbox_transport.lidl"),
##                 interfaceJson = staticRead("interface.json"))
##
## nim-ffi supplies the routing -- arity, argument decoding, the generated
## `case` -- and this supplies what is specific to Logos: the symbol names, the
## `{"_bytes":...}` convention, the rejection vocabulary, and the three
## identity methods every module must answer.
##
## What is still hand-written is `interface.json`, because `logos-lidl-gen` has
## no Nim backend to emit it from the contract. That is the remaining gap.
import std/[json, locks, macros]
import system/ansi_c
import ./dispatch_macro
import ./bytes
import ./wire
import ./events
import ./manifest
import ./lp_client

export dispatch_macro, bytes, wire, events, manifest

type EmitCallback* = proc(name, payload: cstring, userData: pointer)
type UnloadDoneCallback* = proc(userData: pointer)
  {.cdecl, gcsafe, raises: [].}
  ## The host's. `raises: []` because it is reached across a C boundary: an
  ## exception crossing back into Nim from it would be undefined behaviour.

var
  logosLock*: Lock
  emitCb: EmitCallback
  callCaller: string
  persistencePath*: string
    ## Where this instance may keep state, as the host told set_context.
  emitUserData: pointer
  moduleOrigin*: string

initLock(logosLock)

proc cstrdup*(s: string): cstring =
  ## Results are released by `logos_module_string_free`, so they must come from
  ## the allocator that proc frees. Deliberately a fresh block per call and not
  ## a thread-local scratch buffer: the host holds the pointer across calls, so
  ## a module re-entering itself would free its own caller's reply.
  let buf = cast[cstring](c_malloc(csize_t(s.len + 1)))
  if buf != nil: copyMem(buf, s.cstring, s.len + 1)
  return buf

proc emitEvent*(name: string, args: JsonNode) =
  ## Fire-and-forget, with the payload a positional array. The callback pointer
  ## is copied out under the lock and invoked with it released -- the Rust
  ## scaffold calls it while holding its own mutex, which deadlocks any host
  ## that re-enters the module from the callback.
  var cb: EmitCallback
  var ud: pointer
  withLock logosLock:
    cb = emitCb
    ud = emitUserData
  if cb == nil: return
  let payload = $args
  cb(name.cstring, payload.cstring, ud)

proc renderError*(origin: string, e: DispatchError): JsonNode =
  ## nim-ffi reports *what* went wrong; Logos decides how that reads on the
  ## wire. The wording is shared verbatim with the Rust and C++ scaffolds
  ## because consumers match on it.
  case e.kind
  of deArity: invalidArgs(origin, e.wantArity, e.gotArity)
  of deArgType:
    dispatchFailed(origin,
      "expected " & e.wantType & " at arg" & $e.argIndex & ", got " & e.gotType)
  of deRaised: dispatchFailed(origin, e.message)
  of deUnknownMethod: nil    # NULL on the wire, not a structured error

macro buildInterfaceJson*(): untyped =
  ## The manifest, assembled at compile time from the annotations. Methods in
  ## declaration order, then the three identity built-ins, then events -- the
  ## order the Rust generator emits, so the two can be compared byte for byte.
  result = quote do:
    block:
      var entries = newJArray()
      for m in dispatchMethodMeta():
        var ps: seq[(string, string)] = @[]
        for prm in m.params: ps.add((prm.name, prm.nimType))
        entries.add(methodEntry(m.wireName, m.doc, ps, m.returnType))
      for e in identityEntries(): entries.add(e)
      for (wire, params, doc) in logosEventMetaSeq():
        entries.add(eventEntry(wire, doc, params))
      $entries

proc noRuntimeInit*() = discard

template logosModule*(modName, modVersion, contract: static string,
                      ensureRuntime: untyped = noRuntimeInit) =
  ## Terminal. Emits the seven exports, after every `{.dispatchMethod.}` and
  ## `{.logosEvent.}`.
  bind cstrdup, renderError, emitCb, emitUserData, logosLock, moduleOrigin, callCaller, persistencePath, noRuntimeInit

  # The name this image announces when it calls out, set BEFORE any outbound
  # client can exist. Until now it was only ever set by accept_token, so a host
  # that issues no tokens left every outbound call anonymous -- and the origin
  # is the single field the capability story rests on. logos-rust-sdk sets it
  # from the generated constant for the same reason; this is the same fix.
  moduleOrigin = modName

  let logosTable = dispatchTableFor()
  let logosInterface = buildInterfaceJson()

  proc logos_module_dispatch(meth: cstring, argsJson: cstring): cstring
      {.exportc, cdecl, dynlib.} =
    ensureRuntime()
    if meth == nil: return nil
    try:
      var args = newJArray()
      if argsJson != nil:
        let parsed = parseJson($argsJson)
        # A positional array or nothing. An object or a scalar is not a
        # malformed call to answer; it is not a call at all.
        if parsed.kind != JArray: return nil
        args = parsed

      # The three identity methods. Derived built-ins: they are part of the
      # contract for code generation but never appear in the .lidl text.
      case $meth
      of "name":
        if args.len != 0: return cstrdup($invalidArgs(modName, 0, args.len))
        return cstrdup($(%modName))
      of "version":
        if args.len != 0: return cstrdup($invalidArgs(modName, 0, args.len))
        return cstrdup($(%modVersion))
      of "lidl":
        if args.len != 0: return cstrdup($invalidArgs(modName, 0, args.len))
        return cstrdup($(%contract))
      else: discard

      let r = logosTable.dispatch($meth, args)
      if r.ok: return cstrdup($r.value)
      let rendered = renderError(modName, r.err)
      if rendered == nil: return nil        # unknown method
      return cstrdup($rendered)
    except CatchableError, Defect:
      # Nothing may unwind into the host's frame.
      return cstrdup($dispatchFailed(modName, "unhandled exception in " & $meth))

  proc logos_module_get_methods(): cstring {.exportc, cdecl, dynlib.} =
    ensureRuntime()
    return cstrdup(logosInterface)

  proc logos_module_set_context(modulePath, instanceId, instancePersistencePath: cstring)
      {.exportc, cdecl, dynlib.} =
    ## The instance's persistence path is kept for the module; the rest is
    ## accepted and ignored. Present because a host that finds it missing
    ## never fires its context-ready hook.
    ensureRuntime()
    withLock logosLock:
      persistencePath = if instancePersistencePath == nil: "" else: $instancePersistencePath

  proc logos_module_set_emit_callback(cb: EmitCallback, userData: pointer)
      {.exportc, cdecl, dynlib.} =
    ensureRuntime()
    withLock logosLock:
      emitCb = cb
      emitUserData = userData

  proc logos_module_accept_token(moduleName, token: cstring): cint
      {.exportc, cdecl, dynlib.} =
    ## The outbound door: the token this module presents when it calls
    ## `moduleName`. Filed with the protocol layer, which every lp client of
    ## this image reads; it is not the module's name (that is set above).
    ensureRuntime()
    if moduleName == nil or token == nil: return -1
    return if saveOutboundToken($moduleName, $token): 0 else: -1

  proc logos_module_accept_inbound_token(caller, token: cstring): cint
      {.exportc, cdecl, dynlib.} =
    ## The inbound door (protocol >= 0.8): a caller's token, saved by the host.
    ensureRuntime()
    if caller == nil or token == nil: return -1
    return if saveInboundToken($caller, $token): 0 else: -1
  proc logos_module_grant_host_services(servicesJson: cstring): cint
      {.exportc, cdecl, dynlib.} =
    ## Host services this module could be granted (protocol >= 0.3). None used.
    ensureRuntime()
    return 0
  proc logos_module_set_unload_done_callback(cb: UnloadDoneCallback, userData: pointer)
      {.exportc, cdecl, dynlib.} =
    ## Deferred unload (protocol >= 0.5): this module unloads synchronously.
    ensureRuntime()
    discard
  proc logos_module_about_to_unload(): cint {.exportc, cdecl, dynlib.} =
    ensureRuntime()
    return 0
  proc logos_module_set_call_caller(callerJson: cstring)
      {.exportc, cdecl, dynlib.} =
    ## Who is calling (protocol >= 0.6), set around each dispatch; nil clears.
    ensureRuntime()
    withLock logosLock:
      callCaller = if callerJson == nil: "" else: $callerJson
  proc logos_module_get_protocol_version(): cstring {.exportc, cdecl, dynlib.} =
    ## Static storage; the caller must NOT free this one. Everything
    ## logos_module_impl.h 0.9 declares is exported here.
    ensureRuntime()
    return "0.9.0".cstring

  proc logos_module_string_free(s: cstring) {.exportc, cdecl, dynlib.} =
    ensureRuntime()
    if s != nil: c_free(s)
