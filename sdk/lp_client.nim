## Calling another Logos module.
##
## `lp_invoke` is synchronous by signature -- the result leaves through an
## out-parameter -- so this blocks the calling thread for the duration. That is
## not a simplification: logos-cpp-sdk dispatches provider methods with
## Qt::DirectConnection, no pool and no queue, so a call occupies its caller's
## thread on the mainline path too.
##
## The symbols are left undefined at link and bound by the host at dlopen,
## exactly as the Rust cdylib's are.
import std/[json, tables]
import ./wire

const LP_OK* = 0.cint

type LpClientPtr = distinct pointer

proc lp_client_create(target, origin, targetTransport,
                      capabilityTransport: cstring): LpClientPtr {.importc, cdecl.}
proc lp_client_destroy(c: LpClientPtr) {.importc, cdecl.}
proc lp_invoke(c: LpClientPtr, meth, argsJson: cstring, timeoutMs: cint,
               outResult, outError: ptr cstring): cint {.importc, cdecl.}
proc lp_string_free(s: cstring) {.importc, cdecl.}

var clients: Table[string, LpClientPtr]
  ## One handle per (origin, target). The Rust SDK caches the same way, so a
  ## concurrent fan-out coalesces into a single capability handshake instead of
  ## racing N of them.
  ##
  ## Kept as a table of HANDLES rather than of client objects on purpose: a
  ## `var T` returned from a Table is a copy in Nim, so handing callers a
  ## mutable client is a quiet way to open a connection on a temporary and then
  ## send every call through an unopened one.

proc handleFor(target, origin: string): LpClientPtr =
  let key = origin & "\0" & target
  if not clients.hasKey(key):
    # Both transport arguments are NULL: the host chooses. Passing `origin` is
    # the whole point -- it is how the far side learns who is asking.
    clients[key] = lp_client_create(target.cstring, origin.cstring, nil, nil)
  return clients[key]

proc closeClients*() =
  ## For a module tearing down. Not required: the host outlives us.
  for _, h in clients:
    if pointer(h) != nil: lp_client_destroy(h)
  clients.clear()

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
