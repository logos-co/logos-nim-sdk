## Being a Logos module: the seven C exports, over nim-ffi's dispatch profile.
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
import std/[json, locks]
import system/ansi_c
import dispatch_macro          # nim-ffi
import ./bytes
import ./wire

export dispatch_macro, bytes, wire

type EmitCallback* = proc(name, payload: cstring, userData: pointer)
  {.cdecl, gcsafe, raises: [].}
  ## The host's. `raises: []` because it is reached across a C boundary: an
  ## exception crossing back into Nim from it would be undefined behaviour.

var
  logosLock*: Lock
  emitCb: EmitCallback
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

template logosModule*(modName, modVersion, contract, interfaceJson: static string) =
  ## Terminal. Emits the seven exports, after every `{.dispatchMethod.}`.
  bind cstrdup, renderError, emitCb, emitUserData, logosLock, moduleOrigin

  # Logos carries binary as {"_bytes":"<base64url>"}; nim-ffi asks the ABI.
  dispatchBytesDecode = proc(n: JsonNode): seq[byte] {.raises: [].} =
    fromLogosBytes(n)
  dispatchBytesEncode = proc(b: seq[byte]): JsonNode {.raises: [].} =
    toLogosBytes(b)

  let logosTable = dispatchTableFor()

  proc logos_module_dispatch(meth: cstring, argsJson: cstring): cstring
      {.exportc, cdecl, dynlib.} =
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
    return cstrdup(interfaceJson)

  proc logos_module_set_context(modulePath, instanceId, persistencePath: cstring)
      {.exportc, cdecl, dynlib.} =
    ## Accepted and ignored. Present because a host that finds it missing never
    ## fires its context-ready hook.
    discard

  proc logos_module_set_emit_callback(cb: EmitCallback, userData: pointer)
      {.exportc, cdecl, dynlib.} =
    withLock logosLock:
      emitCb = cb
      emitUserData = userData

  proc logos_module_accept_token(moduleName, token: cstring): cint
      {.exportc, cdecl, dynlib.} =
    if moduleName == nil or token == nil: return -1
    withLock logosLock:
      moduleOrigin = $moduleName
    return 0

  proc logos_module_get_protocol_version(): cstring {.exportc, cdecl, dynlib.} =
    ## Static storage; the caller must NOT free this one.
    return "0.1.0".cstring

  proc logos_module_string_free(s: cstring) {.exportc, cdecl, dynlib.} =
    if s != nil: c_free(s)
