## Calling another Logos module.
##
## `lp_invoke` is synchronous by signature -- the result leaves through an
## out-parameter -- so this blocks the calling thread for the duration. That is
## not a simplification: logos-cpp-sdk dispatches provider methods directly on
## the calling thread, with no pool and no queue, so a call occupies its
## caller's thread on the mainline path too.
##
## The symbols are left undefined at link and bound by the host at dlopen,
## exactly as the Rust cdylib's are.
import std/[json, locks, tables]
import results
import ./wire

const LP_OK* = 0.cint

type LpClientPtr = distinct pointer

proc lp_client_create(target, origin, targetTransport,
                      capabilityTransport: cstring): LpClientPtr {.importc, cdecl.}
proc lp_client_destroy(c: LpClientPtr) {.importc, cdecl.}
proc lp_invoke(c: LpClientPtr, meth, argsJson: cstring, timeoutMs: cint,
               outResult, outError: ptr cstring): cint {.importc, cdecl.}
proc lp_string_free(s: cstring) {.importc, cdecl.}

type LpResultCb* = proc(ok: cint, json: cstring, userData: pointer) {.cdecl.}
  ## lp_invoke_async's completion: `ok` non-zero with the result JSON, or zero
  ## with the error object. Arrives on a protocol thread, never the caller's.
proc lp_invoke_async(c: LpClientPtr, meth, argsJson: cstring, timeoutMs: cint,
                     cb: LpResultCb, userData: pointer): cint {.importc, cdecl.}

var
  clients: Table[string, LpClientPtr]
  clientsLock: Lock
    ## Clients are shared by every thread of the image (a module's handlers
    ## run on the host's thread, its node may call out from its own).

initLock(clientsLock)

proc handleFor(target, origin: string): LpClientPtr {.gcsafe, raises: [].} =
  ## One client per (origin, target), made on first use. Both transport
  ## arguments are NULL: the host chooses. Passing `origin` is the whole
  ## point -- it is how the far side learns who is asking.
  let key = origin & "\0" & target
  {.cast(gcsafe).}:
    withLock clientsLock:
      if not clients.hasKey(key):
        clients[key] = lp_client_create(target.cstring, origin.cstring, nil, nil)
      return clients.getOrDefault(key, LpClientPtr(nil))

proc closeClients*() =
  ## For a module tearing down. Not required: the host outlives us.
  for _, h in clients:
    if pointer(h) != nil: lp_client_destroy(h)
  clients.clear()

type LogosCall*[T] = object
  ## What a generated typed client answers with.
  ##
  ## Deliberately not an exception. A refusal is an ordinary outcome on this
  ## ABI -- it arrives as a *successful* dispatch carrying a rejection object --
  ## and an exception escaping a handler is the one thing the module ABI
  ## forbids. A caller that wants to degrade rather than fail, as a transport
  ## with no vault must, can do so by reading `ok`.
  ok*: bool
  value*: T
  error*: string

proc callOk*[T](v: sink T): LogosCall[T] =
  return LogosCall[T](ok: true, value: v)

proc callFailed*[T](msg: string): LogosCall[T] =
  return LogosCall[T](ok: false, error: msg)

proc callModule*(target, origin, meth: string, args: JsonNode,
                 timeoutMs = 0): tuple[ok: bool, value: JsonNode, error: string] =
  ## Positional arguments in, a bare JSON value out.
  ##
  ## Three failure modes, kept apart because they mean different things: the
  ## transport failed (`rc != LP_OK`), the far side answered with something
  ## unparseable, or the far side REFUSED -- which arrives as a perfectly
  ## successful call whose result is a rejection object. Folding that last case
  ## is not optional: without it a refusal reads back as data and the caller
  ## quietly proceeds with a default.
  let handle = handleFor(target, origin)
  if pointer(handle) == nil:
    return (false, nil, "no client for " & target)

  var resJson: cstring = nil
  var errJson: cstring = nil
  let rc = lp_invoke(handle, meth.cstring, ($args).cstring, timeoutMs.cint,
                     addr resJson, addr errJson)
  defer:
    if resJson != nil: lp_string_free(resJson)
    if errJson != nil: lp_string_free(errJson)

  if rc != LP_OK:
    let detail = if errJson != nil: $errJson else: "lp_invoke failed"
    return (false, nil, detail)
  if resJson == nil:
    return (true, newJNull(), "")

  var parsed: JsonNode
  try:
    parsed = parseJson($resJson)
  except CatchableError as e:
    return (false, nil, "unparseable reply from " & target & ": " & e.msg)

  let refused = asRejection(parsed)
  if refused.len > 0:
    return (false, nil, refused)
  return (true, parsed, "")

proc callModuleAsync*(target, origin, meth: string, args: JsonNode, timeoutMs: int,
                      cb: LpResultCb, userData: pointer): Result[void, string] {.gcsafe, raises: [].} =
  ## Fires `meth` at `target` and returns at once; `cb` gets the reply, on a
  ## protocol thread, within `timeoutMs` (the host answers a timeout error
  ## itself). The reply is the module's JSON verbatim -- no rejection fold, so
  ## a caller that wants the raw envelope gets it.
  let handle = handleFor(target, origin)
  if pointer(handle) == nil:
    return err("no client for " & target)
  let argsText = try: $args except CatchableError: "[]"
  let rc = lp_invoke_async(handle, meth.cstring, argsText.cstring, timeoutMs.cint, cb, userData)
  if rc != LP_OK:
    return err("lp_invoke_async failed with " & $rc)
  return ok()
