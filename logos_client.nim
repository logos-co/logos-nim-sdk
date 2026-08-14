## logos_client.nim — the CONSUMER surface of the Logos Nim SDK.
##
## A Nim program reaches another Logos module through the language-neutral
## `lp_*` C ABI of logos-protocol: `lp_client_create` / `lp_invoke` /
## `lp_subscribe` / `lp_client_destroy`. There is no liblogos_core in this
## path and no Qt SDK — a consumer over a plain transport (tcp / tcp_ssl)
## needs no Qt event loop at all.
##
## ## Callbacks and the Nim runtime
##
## `lp_*` callbacks "may arrive on an internal protocol thread — never assume
## they run on your own thread". A Nim `{.cdecl.}` callback that allocated a
## Nim string or ran a closure on such a thread would be touching a runtime
## that was never initialised there. So the C trampolines below do exactly one
## thing: copy the two `char*` with `c_malloc` and push a raw node onto a
## mutex-guarded intrusive list. Every Nim-level allocation, closure call and
## JSON parse happens later in `poll()`, on the thread that owns the client.
##
## That makes the delivery model explicit rather than accidental: results of
## `invokeAsync` and every `subscribe` payload are handed to your handlers
## when you call `poll()` / `pollFor()`. The synchronous `invoke()` needs none
## of this — it blocks in `lp_invoke` and returns the parsed result.

import std/[json, locks, times, os, base64, strutils]
import system/ansi_c

import logos_protocol
export logos_protocol.LogosProtocolError, logos_protocol.loadProtocol,
       logos_protocol.protocolVersion, logos_protocol.protocolAbiMajor,
       logos_protocol.protocolLibPath, logos_protocol.isProtocolLoaded,
       logos_protocol.setMode, logos_protocol.getMode,
       logos_protocol.setDefaultTransport,
       logos_protocol.tokenGet, logos_protocol.tokenSave,
       logos_protocol.LP_OK

type
  LogosCallError* = object of CatchableError
    ## Raised by `invoke` when the call failed structurally. Mirrors the
    ## canonical error object the ABI reports:
    ## `{"code":..., "message":..., "origin":...}`.
    code*: string
    origin*: string

  CallOutcome* = object
    ## Non-raising twin of `invoke`.
    ok*: bool
    value*: JsonNode  ## result JSON value when `ok`
    code*: string     ## machine code when not `ok`
    message*: string
    origin*: string

  ResultHandler* = proc (outcome: CallOutcome) {.closure.}
  EventHandler* = proc (eventName: string, payload: JsonNode) {.closure.}

  ModuleClient* = ref object
    ## A client for calling ONE target module on behalf of `origin`.
    target*: string
    origin*: string
    handle: LpClient
    subs: seq[tuple[id: int32, sub: LpSubscription]]
    closed: bool

  Subscription* = ref object
    ## Handle returned by `subscribe`; `cancel` it to stop delivery.
    client: ModuleClient
    id: int32
    sub: LpSubscription

# ---------------------------------------------------------------------------
# Transport config helpers — the JSON objects lp_* takes verbatim.
# ---------------------------------------------------------------------------

proc localTransport*(): string =
  ## Qt-affine in-process/local-socket transport (the process default).
  """{"protocol":"local"}"""

proc tcpTransport*(host = "127.0.0.1", port: int, codec = "json"): string =
  ## Qt-free plain TCP. A consumer on this transport needs no Qt event loop.
  $(%*{"protocol": "tcp", "host": host, "port": port, "codec": codec})

proc tcpSslTransport*(host: string, port: int, codec = "json", caFile = "",
                      certFile = "", keyFile = "",
                      verifyPeer = true): string =
  ## Qt-free plain TCP + TLS.
  var o = %*{"protocol": "tcp_ssl", "host": host, "port": port,
             "codec": codec, "verify_peer": verifyPeer}
  if caFile.len > 0: o["ca_file"] = %caFile
  if certFile.len > 0: o["cert_file"] = %certFile
  if keyFile.len > 0: o["key_file"] = %keyFile
  $o

# ---------------------------------------------------------------------------
# Bytes: the ABI encodes binary as {"_bytes": "<base64url>"} inside JSON.
# ---------------------------------------------------------------------------

proc bytesArg*(data: string): JsonNode =
  ## Wrap raw bytes in the canonical `{"_bytes": "<base64url>"}` envelope.
  %*{"_bytes": encode(data, safe = true)}

proc isBytes*(n: JsonNode): bool =
  n != nil and n.kind == JObject and n.len == 1 and n.hasKey("_bytes")

proc bytesValue*(n: JsonNode): string =
  ## Decode a `{"_bytes": ...}` envelope back to raw bytes.
  if not isBytes(n):
    raise newException(ValueError, "not a {\"_bytes\": ...} envelope: " & $n)
  decode(n["_bytes"].getStr())

# ---------------------------------------------------------------------------
# The cross-thread delivery queue.
#
# Nodes are plain C memory pushed by the protocol thread and popped by the
# owner thread. NOTHING in the push path touches the Nim heap.
# ---------------------------------------------------------------------------

type
  QNodeKind = enum qnResult, qnEvent
  QNode = object
    next: ptr QNode
    kind: QNodeKind
    id: int32
    ok: cint
    name: cstring     # event name (qnEvent only); c_malloc'd or nil
    payload: cstring  # result / error / event JSON; c_malloc'd or nil

var
  gQueueLock: Lock
  gQueueHead: ptr QNode
  gQueueTail: ptr QNode
  gNextId: int32 = 1

gQueueLock.initLock()

proc cdup(s: cstring): cstring =
  ## malloc + copy. Returns nil for nil (never allocates a Nim string).
  if s.isNil: return nil
  var n = 0
  while s[n] != '\0': inc n
  let mem = cast[cstring](c_malloc(csize_t(n + 1)))
  if mem.isNil: return nil
  copyMem(mem, s, n + 1)
  mem

proc pushNode(kind: QNodeKind, id: int32, ok: cint,
              name, payload: cstring) {.raises: [].} =
  let node = cast[ptr QNode](c_malloc(csize_t(sizeof(QNode))))
  if node.isNil: return
  node.next = nil
  node.kind = kind
  node.id = id
  node.ok = ok
  node.name = cdup(name)
  node.payload = cdup(payload)
  acquire(gQueueLock)
  if gQueueTail.isNil:
    gQueueHead = node
    gQueueTail = node
  else:
    gQueueTail.next = node
    gQueueTail = node
  release(gQueueLock)

proc popNode(): ptr QNode {.raises: [].} =
  acquire(gQueueLock)
  result = gQueueHead
  if not result.isNil:
    gQueueHead = result.next
    if gQueueHead.isNil: gQueueTail = nil
    result.next = nil
  release(gQueueLock)

proc freeNode(node: ptr QNode) {.raises: [].} =
  if node.isNil: return
  if not node.name.isNil: c_free(node.name)
  if not node.payload.isNil: c_free(node.payload)
  c_free(node)

# The C trampolines. `userData` carries the registration id as an integer, so
# no Nim object is ever handed across the ABI.

proc resultTrampoline(ok: cint, json: cstring,
                      userData: pointer) {.cdecl, raises: [].} =
  pushNode(qnResult, int32(cast[int](userData)), ok, nil, json)

proc eventTrampoline(eventName, dataJson: cstring,
                     userData: pointer) {.cdecl, raises: [].} =
  pushNode(qnEvent, int32(cast[int](userData)), 1, eventName, dataJson)

# Nim-side registries. Touched only from the thread that calls invokeAsync /
# subscribe / poll — never from a trampoline.
type PendingCall = object
  id: int32
  h: ResultHandler
  owner: ModuleClient
  target: string
  meth: string
  deadline: float  # epochTime() past which poll() answers for the library

var
  gPendingCalls: seq[PendingCall] = @[]
  gEventHandlers: seq[tuple[id: int32, h: EventHandler]] = @[]

const
  defaultInvokeTimeoutMs* = 20_000
    ## What `timeoutMs <= 0` means to the C ABI today. Used ONLY to size this
    ## SDK's own watchdog (below); the library still applies its own default.
  asyncWatchdogGraceMs* = 1_000
    ## How long past a call's own deadline `poll()` waits for the library
    ## before answering on its behalf. Large enough that a real, in-time
    ## result always wins the race.

proc nextId(): int32 =
  result = gNextId
  inc gNextId

proc takeCall(id: int32): ResultHandler =
  for i in 0 ..< gPendingCalls.len:
    if gPendingCalls[i].id == id:
      result = gPendingCalls[i].h
      gPendingCalls.delete(i)
      return
  nil

proc findEvent(id: int32): EventHandler =
  for e in gEventHandlers:
    if e.id == id: return e.h
  nil

proc dropEvent(id: int32) =
  for i in 0 ..< gEventHandlers.len:
    if gEventHandlers[i].id == id:
      gEventHandlers.delete(i)
      return

# ---------------------------------------------------------------------------
# Error decoding
# ---------------------------------------------------------------------------

proc parseJsonOrNull(s: string): JsonNode =
  if s.len == 0: return newJNull()
  try: parseJson(s)
  except CatchableError: newJString(s)

proc outcomeFromError(errJson: string): CallOutcome =
  let n = parseJsonOrNull(errJson)
  result = CallOutcome(ok: false, value: newJNull(),
                       code: "unknown", message: errJson, origin: "")
  if n.kind == JObject:
    if n.hasKey("code"): result.code = n["code"].getStr()
    if n.hasKey("message"): result.message = n["message"].getStr()
    if n.hasKey("origin"): result.origin = n["origin"].getStr()

proc raiseCallError(target, meth: string, o: CallOutcome) =
  var e = newException(LogosCallError,
    "call " & target & "." & meth & " failed [" & o.code & "]: " & o.message)
  e.code = o.code
  e.origin = if o.origin.len > 0: o.origin else: target
  raise e

# ---------------------------------------------------------------------------
# ModuleClient
# ---------------------------------------------------------------------------

proc newModuleClient*(target, origin: string,
                      targetTransport = "",
                      capabilityTransport = ""): ModuleClient =
  ## Create a consumer client for `target` on behalf of `origin`.
  ##
  ## Empty transports select the process default. The capability transport is
  ## used by the automatic `requestModule` token-fetch flow, which the library
  ## performs transparently the first time a target requires a token — Nim gets
  ## that flow for free, exactly like every other language on this ABI.
  loadProtocol()
  let h = clientCreate(target, origin, targetTransport, capabilityTransport)
  if h.isNil:
    raise newException(LogosProtocolError,
      "lp_client_create refused target='" & target & "' origin='" & origin &
      "' (check the transport JSON)")
  ModuleClient(target: target, origin: origin, handle: h, subs: @[],
               closed: false)

proc isClosed*(m: ModuleClient): bool = m.closed

proc close*(m: ModuleClient) =
  ## Destroy the client. After this returns no further callbacks fire for it
  ## or its subscriptions; queued-but-undelivered payloads are dropped, and so
  ## are async calls still in flight (including their watchdog deadlines).
  if m.isNil or m.closed: return
  for s in m.subs:
    unsubscribeRaw(s.sub)
    dropEvent(s.id)
  m.subs.setLen(0)
  var i = 0
  while i < gPendingCalls.len:
    if gPendingCalls[i].owner == m: gPendingCalls.delete(i)
    else: inc i
  clientDestroy(m.handle)
  m.handle = nil
  m.closed = true

proc checkOpen(m: ModuleClient) =
  if m.isNil or m.closed:
    raise newException(LogosProtocolError, "client is closed")

proc argsToJsonArray(args: JsonNode): string =
  if args.isNil: return "[]"
  if args.kind == JArray: return $args
  $(%*[args])

proc tryInvoke*(m: ModuleClient, meth: string, args: JsonNode = nil,
                timeoutMs = 0): CallOutcome =
  ## Blocking call that reports failure instead of raising.
  ## `timeoutMs <= 0` selects the library default (currently 20s).
  checkOpen(m)
  var resJson, errJson: string
  let rc = invokeRaw(m.handle, meth, argsToJsonArray(args), timeoutMs,
                     resJson, errJson)
  if rc == int(LP_OK):
    CallOutcome(ok: true, value: parseJsonOrNull(resJson))
  else:
    outcomeFromError(errJson)

proc invoke*(m: ModuleClient, meth: string, args: JsonNode = nil,
             timeoutMs = 0): JsonNode =
  ## Blocking call. Returns the result JSON value; raises `LogosCallError`
  ## on a structural failure (target unavailable, deadline exceeded, rejected
  ## token, module not loaded).
  let o = tryInvoke(m, meth, args, timeoutMs)
  if not o.ok: raiseCallError(m.target, meth, o)
  o.value

proc invoke*(m: ModuleClient, meth: string, args: openArray[JsonNode],
             timeoutMs = 0): JsonNode =
  var arr = newJArray()
  for a in args: arr.add a
  m.invoke(meth, arr, timeoutMs)

proc invokeAsync*(m: ModuleClient, meth: string, args: JsonNode = nil,
                  timeoutMs = 0, handler: ResultHandler) =
  ## Dispatch a call and deliver its outcome to `handler` from `poll()`.
  ## Raises only when the arguments/handle are refused synchronously.
  checkOpen(m)
  if handler.isNil:
    raise newException(ValueError, "invokeAsync needs a handler")
  let id = nextId()
  let budget = if timeoutMs > 0: timeoutMs else: defaultInvokeTimeoutMs
  gPendingCalls.add(PendingCall(
    id: id, h: handler, owner: m, target: m.target, meth: meth,
    deadline: epochTime() + float(budget + asyncWatchdogGraceMs) / 1000.0))
  let rc = invokeAsyncRaw(m.handle, meth, argsToJsonArray(args), timeoutMs,
                          resultTrampoline, cast[pointer](int(id)))
  if rc != int(LP_OK):
    discard takeCall(id)
    raise newException(LogosProtocolError,
      "lp_invoke_async refused " & m.target & "." & meth &
      " (rc=" & $rc & ")")

proc subscribe*(m: ModuleClient, eventName: string,
                handler: EventHandler): Subscription =
  ## Subscribe to an event of the target module. Payloads are delivered from
  ## `poll()`.
  ##
  ## The target does NOT have to be reachable yet — the subscription is held
  ## and armed when the module appears — so a failure here means the ARGUMENTS
  ## were refused. Use `pendingSubscriptions` to see what has not armed.
  checkOpen(m)
  if handler.isNil:
    raise newException(ValueError, "subscribe needs a handler")
  let id = nextId()
  gEventHandlers.add((id, handler))
  let sub = subscribeRaw(m.handle, eventName, eventTrampoline,
                         cast[pointer](int(id)))
  if sub.isNil:
    dropEvent(id)
    raise newException(LogosProtocolError,
      "lp_subscribe refused " & m.target & "::" & eventName)
  m.subs.add((id, sub))
  Subscription(client: m, id: id, sub: sub)

proc cancel*(s: Subscription) =
  ## Cancel a subscription. Delivery stops immediately; the client stops
  ## TRACKING it on a later turn of its owner thread's loop, so a just-
  ## cancelled entry may briefly still appear in `pendingSubscriptions`.
  if s.isNil or s.sub.isNil: return
  unsubscribeRaw(s.sub)
  dropEvent(s.id)
  if not s.client.isNil:
    for i in 0 ..< s.client.subs.len:
      if s.client.subs[i].id == s.id:
        s.client.subs.delete(i)
        break
  s.sub = nil

proc pendingSubscriptions*(m: ModuleClient): JsonNode =
  ## Diagnostics: `["<module>::<event>", ...]` for subscriptions accepted but
  ## not yet armed. `[]` when everything is live.
  checkOpen(m)
  parseJsonOrNull(logos_protocol.pendingSubscriptions(m.handle))

proc getMethods*(m: ModuleClient): JsonNode =
  ## The target module's methods/events (the shape `lm` prints).
  checkOpen(m)
  parseJsonOrNull(getMethodsJson(m.handle))

# ---------------------------------------------------------------------------
# Delivery pump
# ---------------------------------------------------------------------------

proc sweepExpired(): int =
  ## Answer, on the library's behalf, for async calls whose own deadline has
  ## passed with no callback.
  ##
  ## This is not belt-and-braces. `lp_invoke_async` routes a first call to an
  ## un-tokened target through an ASYNC `requestModule` handshake, and when
  ## `capability_module` itself cannot be acquired that handshake's own
  ## callback never runs — so the queued continuation, and with it the caller's
  ## handler, is dropped rather than failed. (The synchronous twin `lp_invoke`
  ## does not have this hole; it reports `object_unavailable` correctly, which
  ## is why `invoke` needs no watchdog.) A consumer that hangs forever on an
  ## unreachable module is the worst possible shape for that bug, so the
  ## deadline is enforced here rather than waited on.
  result = 0
  if gPendingCalls.len == 0: return
  let now = epochTime()
  var i = 0
  while i < gPendingCalls.len:
    if gPendingCalls[i].deadline <= now:
      let p = gPendingCalls[i]
      gPendingCalls.delete(i)
      if not p.h.isNil:
        p.h(CallOutcome(ok: false, value: newJNull(), code: "timeout",
                        message: "no result for " & p.target & "." & p.meth &
                                 " before its deadline",
                        origin: p.target))
      inc result
    else:
      inc i

proc poll*(maxItems = 0): int {.discardable.} =
  ## Deliver queued async results and event payloads to their handlers on the
  ## calling thread. Returns how many items were delivered. `maxItems <= 0`
  ## drains everything currently queued.
  result = 0
  while maxItems <= 0 or result < maxItems:
    let node = popNode()
    if node.isNil: break
    let payload = if node.payload.isNil: "" else: $node.payload
    let name = if node.name.isNil: "" else: $node.name
    let kind = node.kind
    let id = node.id
    let ok = node.ok
    freeNode(node)
    case kind
    of qnResult:
      let h = takeCall(id)
      if not h.isNil:
        if ok != 0:
          h(CallOutcome(ok: true, value: parseJsonOrNull(payload)))
        else:
          h(outcomeFromError(payload))
    of qnEvent:
      let h = findEvent(id)
      if not h.isNil:
        h(name, parseJsonOrNull(payload))
    inc result
  result += sweepExpired()

proc pollFor*(timeoutMs: int, intervalMs = 10): int {.discardable.} =
  ## Pump for up to `timeoutMs`, sleeping `intervalMs` between drains.
  ## Returns the total number of items delivered.
  result = 0
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while true:
    result += poll()
    if epochTime() >= deadline: break
    sleep(intervalMs)

proc waitFor*(timeoutMs: int, pred: proc (): bool {.closure.},
              intervalMs = 10): bool {.discardable.} =
  ## Pump until `pred()` is true or the deadline passes.
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while true:
    discard poll()
    if pred(): return true
    if epochTime() >= deadline: return false
    sleep(intervalMs)

# ---------------------------------------------------------------------------
# LogosClient — one origin identity, many targets.
# ---------------------------------------------------------------------------

type
  LogosClient* = ref object
    ## Convenience front end: caches one `ModuleClient` per target module,
    ## all sharing this consumer's origin identity and transport defaults.
    origin*: string
    targetTransport: string
    capabilityTransport: string
    cache: seq[tuple[name: string, c: ModuleClient]]

proc newLogosClient*(origin: string, targetTransport = "",
                     capabilityTransport = ""): LogosClient =
  loadProtocol()
  LogosClient(origin: origin, targetTransport: targetTransport,
              capabilityTransport: capabilityTransport, cache: @[])

proc module*(l: LogosClient, name: string): ModuleClient =
  ## The (cached) client for `name`.
  for e in l.cache:
    if e.name == name: return e.c
  let cap = if l.capabilityTransport.len > 0: l.capabilityTransport
            else: l.targetTransport
  result = newModuleClient(name, l.origin, l.targetTransport, cap)
  l.cache.add((name, result))

proc close*(l: LogosClient) =
  for e in l.cache: e.c.close()
  l.cache.setLen(0)

# ---------------------------------------------------------------------------
# Legacy parameter shape.
#
# liblogos_core's FFI took `[{"name":..,"value":..,"type":..}, ...]`; lp_invoke
# takes a plain JSON array of values. This is the same translation
# logos-module-client's logos_sdk_c.cpp performs for the other FFI SDKs, so a
# caller that still builds the old shape keeps working.
# ---------------------------------------------------------------------------

proc legacyParamsToArgs*(paramsJson: string): JsonNode =
  ## Convert the historical `[{name,value,type}]` array to a plain args array.
  ## A non-array (or empty) input yields `[]`.
  result = newJArray()
  if paramsJson.strip().len == 0: return
  var parsed: JsonNode
  try: parsed = parseJson(paramsJson)
  except CatchableError:
    raise newException(ValueError, "JSON parse error: " & paramsJson)
  if parsed.kind != JArray: return
  for entry in parsed:
    if entry.kind != JObject or not entry.hasKey("value"):
      result.add entry
      continue
    let value = entry["value"]
    let ptype = if entry.hasKey("type") and entry["type"].kind == JString:
                  entry["type"].getStr() else: ""
    let name = if entry.hasKey("name") and entry["name"].kind == JString:
                 entry["name"].getStr() else: ""
    if value.kind == JString and (ptype == "int" or ptype == "uint"):
      try: result.add newJInt(parseBiggestInt(value.getStr()))
      except ValueError:
        raise newException(ValueError, "Invalid parameter: " & name)
    elif value.kind == JString and (ptype == "double" or ptype == "float"):
      try: result.add newJFloat(parseFloat(value.getStr()))
      except ValueError:
        raise newException(ValueError, "Invalid parameter: " & name)
    elif value.kind == JString and ptype == "bool":
      result.add newJBool(value.getStr() == "true")
    else:
      result.add value
