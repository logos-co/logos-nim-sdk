## logos_protocol.nim — raw Nim bindings for the logos-protocol `lp_*` C ABI.
##
## This is the ONE seam every Logos SDK builds on (see
## `logos-protocol/cpp/logos_protocol.h`). The data model is JSON-in-strings:
## method arguments are a JSON array, results are a JSON value, event payloads
## are a JSON array — all UTF-8 `cstring`.
##
## Symbols are bound at run time out of the SHARED build of the library
## (`liblogos_protocol.{dylib,so,dll}`), which exists precisely for
## out-of-plugin callers that bind `lp_*` via dlopen/FFI. `liblogos_core` links
## the STATIC archive and does NOT re-export `lp_*` (measured: zero `_lp_`
## symbols in its export table on macOS), so resolving through an already-open
## core handle is not an option — the shared library must be loaded on its own.
##
## Nothing in this module allocates through the Nim runtime inside a C
## callback; see `logos_client.nim` for why that matters.

import std/[os, strutils, dynlib]

type
  LogosProtocolError* = object of CatchableError
    ## Raised when the shared library cannot be found/loaded or a required
    ## symbol is missing.

  LpClient* = pointer
    ## Opaque `lp_client*`.
  LpSubscription* = pointer
    ## Opaque `lp_subscription*`.

  LpResultCb* = proc (ok: cint, json: cstring, userData: pointer) {.cdecl.}
    ## Result callback for `lp_invoke_async`. `ok != 0` → `json` is the result
    ## JSON value; `ok == 0` → `json` is the canonical error object. `json` is
    ## only valid for the duration of the callback.

  LpEventCb* = proc (eventName: cstring, dataJson: cstring,
                     userData: pointer) {.cdecl.}
    ## Event callback for `lp_subscribe`. `dataJson` is a JSON array.

const
  LP_OK* = 0.cint
  LP_ERR_INVALID_ARG* = (-1).cint
  LP_ERR_UNSUPPORTED* = (-2).cint
  LP_ERR_INTERNAL* = (-3).cint
  LP_ERR_UNAVAILABLE* = (-4).cint

type
  ProtocolLib = object
    handle: LibHandle
    path: string
    # version / memory
    lp_protocol_version: proc (): cstring {.cdecl.}
    lp_protocol_abi_major: proc (): cint {.cdecl.}
    lp_string_free: proc (s: cstring) {.cdecl.}
    # process-global mode / transport
    lp_set_mode: proc (mode: cstring): cint {.cdecl.}
    lp_get_mode: proc (): cstring {.cdecl.}
    lp_set_default_transport: proc (transportJson: cstring): cint {.cdecl.}
    # consumer
    lp_client_create: proc (target, origin, targetTransport,
                            capabilityTransport: cstring): LpClient {.cdecl.}
    lp_client_destroy: proc (client: LpClient) {.cdecl.}
    lp_invoke: proc (client: LpClient, meth, argsJson: cstring,
                     timeoutMs: cint, outResult, outError: ptr cstring): cint {.cdecl.}
    lp_invoke_async: proc (client: LpClient, meth, argsJson: cstring,
                           timeoutMs: cint, cb: LpResultCb,
                           userData: pointer): cint {.cdecl.}
    lp_subscribe: proc (client: LpClient, eventName: cstring, cb: LpEventCb,
                        userData: pointer): LpSubscription {.cdecl.}
    lp_unsubscribe: proc (sub: LpSubscription) {.cdecl.}
    lp_pending_subscriptions: proc (client: LpClient): cstring {.cdecl.}
    lp_get_methods: proc (client: LpClient): cstring {.cdecl.}
    # tokens (consumer half)
    lp_token_get: proc (moduleName: cstring): cstring {.cdecl.}
    lp_token_save: proc (moduleName, token: cstring): cint {.cdecl.}

var gLib: ProtocolLib

proc libExtension*(): string =
  ## Platform shared-library suffix.
  when defined(macosx): ".dylib"
  elif defined(windows): ".dll"
  else: ".so"

proc libBaseName*(): string =
  when defined(windows): "logos_protocol"
  else: "liblogos_protocol"

proc protocolLibCandidates*(explicit = ""): seq[string] =
  ## Search order for the shared protocol library, most specific first.
  ##
  ## `LOGOS_PROTOCOL_LIB` is the same knob logos-js-sdk uses, so a nix check or
  ## a dev shell can point every SDK at one store path.
  let ext = libExtension()
  let base = libBaseName() & ext
  result = @[]
  if explicit.len > 0: result.add explicit
  let fromEnv = getEnv("LOGOS_PROTOCOL_LIB")
  if fromEnv.len > 0: result.add fromEnv
  let root = getEnv("LOGOS_PROTOCOL_ROOT")
  if root.len > 0:
    result.add(root / "lib" / base)
    result.add(root / "bin" / base)
  # Alongside the executable, and in the usual bundle layout next to it.
  try:
    let appDir = getAppDir()
    result.add(appDir / base)
    result.add(appDir / ".." / "lib" / base)
  except OSError:
    discard
  # Last resort: let the dynamic loader search its own paths.
  result.add base

proc symOrNil[T](handle: LibHandle, name: string): T =
  cast[T](symAddr(handle, name))

proc requireSym[T](handle: LibHandle, path, name: string): T =
  let p = symAddr(handle, name)
  if p.isNil:
    raise newException(LogosProtocolError,
      "symbol '" & name & "' not found in " & path &
      " — is this the SHARED logos-protocol build?")
  cast[T](p)

proc isProtocolLoaded*(): bool =
  not gLib.handle.isNil

proc protocolLibPath*(): string =
  ## Path of the loaded shared library ("" when nothing is loaded yet).
  gLib.path

proc loadProtocol*(libPath = "") =
  ## Load `liblogos_protocol` and bind the `lp_*` entry points. Idempotent —
  ## a second call with the library already loaded is a no-op.
  ##
  ## Raises `LogosProtocolError` when no candidate can be loaded, listing every
  ## path tried; a mute failure here surfaces much later as "every call times
  ## out", which is exactly the failure mode that is expensive to diagnose.
  if not gLib.handle.isNil: return

  let candidates = protocolLibCandidates(libPath)
  var handle: LibHandle
  var chosen = ""
  for c in candidates:
    handle = loadLib(c)
    if not handle.isNil:
      chosen = c
      break
  if handle.isNil:
    raise newException(LogosProtocolError,
      "could not load the shared logos-protocol library. Tried: " &
      candidates.join(", ") &
      ". Set LOGOS_PROTOCOL_LIB to <logos-protocol>/lib/" &
      libBaseName() & libExtension() & ".")

  gLib.handle = handle
  gLib.path = chosen

  template need(field, name: untyped) =
    gLib.field = requireSym[typeof(gLib.field)](handle, chosen, name)

  need(lp_protocol_version, "lp_protocol_version")
  need(lp_protocol_abi_major, "lp_protocol_abi_major")
  need(lp_string_free, "lp_string_free")
  need(lp_set_mode, "lp_set_mode")
  need(lp_get_mode, "lp_get_mode")
  need(lp_set_default_transport, "lp_set_default_transport")
  need(lp_client_create, "lp_client_create")
  need(lp_client_destroy, "lp_client_destroy")
  need(lp_invoke, "lp_invoke")
  need(lp_invoke_async, "lp_invoke_async")
  need(lp_subscribe, "lp_subscribe")
  need(lp_unsubscribe, "lp_unsubscribe")
  need(lp_get_methods, "lp_get_methods")
  need(lp_token_get, "lp_token_get")
  need(lp_token_save, "lp_token_save")
  # Diagnostics-only; present since protocol 0.2 but not worth failing over.
  gLib.lp_pending_subscriptions =
    symOrNil[proc (client: LpClient): cstring {.cdecl.}](
      handle, "lp_pending_subscriptions")

template ensureLoaded() =
  if gLib.handle.isNil: loadProtocol()

# ---------------------------------------------------------------------------
# Thin, safe wrappers. Every `char*` the library returns is owned by us and is
# released with lp_string_free before the Nim copy is handed back.
# ---------------------------------------------------------------------------

proc lpStringFree*(s: cstring) =
  ## Free a string returned by the library. Safe on nil.
  ensureLoaded()
  gLib.lp_string_free(s)

proc takeString(s: cstring): string =
  ## Copy an owned `char*` into a Nim string and free the original.
  if s.isNil: return ""
  result = $s
  gLib.lp_string_free(s)

proc protocolVersion*(): string =
  ## "MAJOR.MINOR.PATCH" of the linked logos-protocol. Static — not freed.
  ensureLoaded()
  let v = gLib.lp_protocol_version()
  if v.isNil: "" else: $v

proc protocolAbiMajor*(): int =
  ## Equal majors interoperate; unequal majors do not.
  ensureLoaded()
  int(gLib.lp_protocol_abi_major())

proc setMode*(mode: string): bool {.discardable.} =
  ## Process-wide mode: "remote" (IPC, default), "local" or "mock".
  ensureLoaded()
  gLib.lp_set_mode(mode.cstring) == LP_OK

proc getMode*(): string =
  ensureLoaded()
  let m = gLib.lp_get_mode()
  if m.isNil: "" else: $m

proc setDefaultTransport*(transportJson: string): bool {.discardable.} =
  ## Process-global default transport, e.g. `{"protocol":"tcp","host":...}`.
  ensureLoaded()
  gLib.lp_set_default_transport(transportJson.cstring) == LP_OK

proc clientCreate*(target, origin: string,
                   targetTransportJson = "",
                   capabilityTransportJson = ""): LpClient =
  ## `lp_client_create`. Empty transport strings mean "process default".
  ## Returns nil when the arguments are refused.
  ensureLoaded()
  let t: cstring = if targetTransportJson.len > 0: targetTransportJson.cstring
                   else: nil
  let c: cstring = if capabilityTransportJson.len > 0: capabilityTransportJson.cstring
                   else: nil
  gLib.lp_client_create(target.cstring, origin.cstring, t, c)

proc clientDestroy*(client: LpClient) =
  ## `lp_client_destroy`. Safe from any thread; teardown is deferred to the
  ## client's owner thread when called elsewhere, but the ABI's
  ## "no callbacks after this returns" guarantee holds regardless.
  if client.isNil: return
  ensureLoaded()
  gLib.lp_client_destroy(client)

proc invokeRaw*(client: LpClient, meth, argsJson: string, timeoutMs: int,
                resultJson, errorJson: var string): int =
  ## `lp_invoke`. Blocks until the result arrives or the timeout elapses
  ## (`timeoutMs <= 0` selects the library default, currently 20s).
  ensureLoaded()
  resultJson = ""
  errorJson = ""
  var outRes: cstring = nil
  var outErr: cstring = nil
  let rc = gLib.lp_invoke(client, meth.cstring, argsJson.cstring,
                          timeoutMs.cint, addr outRes, addr outErr)
  if not outRes.isNil: resultJson = takeString(outRes)
  if not outErr.isNil: errorJson = takeString(outErr)
  int(rc)

proc invokeAsyncRaw*(client: LpClient, meth, argsJson: string, timeoutMs: int,
                     cb: LpResultCb, userData: pointer): int =
  ## `lp_invoke_async`. LP_OK means "dispatched", never "succeeded".
  ensureLoaded()
  int(gLib.lp_invoke_async(client, meth.cstring, argsJson.cstring,
                           timeoutMs.cint, cb, userData))

proc subscribeRaw*(client: LpClient, eventName: string, cb: LpEventCb,
                   userData: pointer): LpSubscription =
  ## `lp_subscribe`. A nil return means the ARGUMENTS were refused — never
  ## "the module is not there yet"; a subscription to an absent module is held
  ## and armed when the module appears.
  ensureLoaded()
  gLib.lp_subscribe(client, eventName.cstring, cb, userData)

proc unsubscribeRaw*(sub: LpSubscription) =
  if sub.isNil: return
  ensureLoaded()
  gLib.lp_unsubscribe(sub)

proc pendingSubscriptions*(client: LpClient): string =
  ## JSON array of `"<module>::<event>"` for subscriptions accepted but not
  ## yet armed. `"[]"` when everything is live.
  ensureLoaded()
  if gLib.lp_pending_subscriptions.isNil: return "[]"
  let s = gLib.lp_pending_subscriptions(client)
  if s.isNil: "[]" else: takeString(s)

proc getMethodsJson*(client: LpClient): string =
  ## The target module's methods/events as a JSON array (what `lm` prints).
  ensureLoaded()
  let s = gLib.lp_get_methods(client)
  if s.isNil: "" else: takeString(s)

proc tokenGet*(moduleName: string): string =
  ensureLoaded()
  let s = gLib.lp_token_get(moduleName.cstring)
  if s.isNil: "" else: takeString(s)

proc tokenSave*(moduleName, token: string): bool {.discardable.} =
  ensureLoaded()
  gLib.lp_token_save(moduleName.cstring, token.cstring) == LP_OK
