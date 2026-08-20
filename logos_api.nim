## logos_api.nim — the Logos Nim SDK.
##
## Two halves, on two different C ABIs:
##
## * **Runtime / host half** (`newLogosAPI`, `start`, `processModule`,
##   `loadModule`, `cleanup`, …) drives an EMBEDDED Logos core through
##   `liblogos_core`'s `logos_core_*` C API. Modules run in their own
##   `logos_host` child processes; this half only discovers and loads them.
##
## * **Consumer half** (`client`, `PluginProxy.invoke` / `.call` / `.on`,
##   `callPluginMethodAsync`, `registerEventListener`) reaches those modules
##   through the language-neutral `lp_*` C ABI of logos-protocol — the seam the
##   Rust and JS SDKs bind. It used to go through
##   `logos_core_call_plugin_method_async` / `logos_core_register_event_listener`,
##   which no longer exist: the protocol extraction removed them from
##   liblogos_core, so this half had no working implementation at all.
##
## Nothing here needs Qt. Give each module a plain (`tcp`) transport with
## `setModuleTransport` before loading it and the whole process — core,
## consumer and all — runs without a Qt event loop. Consumers that do not
## embed a core at all should use `logos_client.newLogosClient` directly.

import os, strformat
import dynlib
import std/[strutils, json, tables]

import logos_client
import logos_protocol as lp

export logos_client
export lp.LogosProtocolError

type
  Param* = object
    name*: string
    value*: string
    ptype*: string

  LogosCallback* = proc(success: bool, message: string)

  PluginProxy* = object
    api*: LogosAPI
    name*: string

  LogosAPI* = ref object
    # ── runtime half (liblogos_core) ──────────────────────────────────────
    lib: LibHandle
    libPath*: string
    modulesDirs*: seq[string]
    isInitialized*: bool
    isStarted*: bool
    p_init: proc (argc: cint, argv: pointer) {.cdecl.}
    p_add_modules_dir: proc (dir: cstring) {.cdecl.}
    p_start: proc () {.cdecl.}
    p_cleanup: proc () {.cdecl.}
    p_get_loaded_modules: proc (): ptr cstring {.cdecl.}
    p_get_known_modules: proc (): ptr cstring {.cdecl.}
    p_process_module: proc (path: cstring): cstring {.cdecl.}
    p_load_module: proc (name: cstring, withDeps: bool): cint {.cdecl.}
    p_unload_module: proc (name: cstring, withDependents: bool): cint {.cdecl.}
    p_get_modules_info: proc (): cstring {.cdecl.}
    p_get_token: proc (key: cstring): cstring {.cdecl.}
    p_set_module_transports: proc (name, json: cstring) {.cdecl.}
    p_set_persistence_base_path: proc (path: cstring) {.cdecl.}
    p_refresh_modules: proc () {.cdecl.}
    # ── consumer half (lp_*) ──────────────────────────────────────────────
    originModule*: string
      ## Identity this process presents to other modules. "core" is the
      ## historical origin the FFI facades have always used.
    transports: Table[string, string]
      ## module name -> transport JSON, as registered with the loader. The
      ## consumer dials the SAME endpoint the module was told to bind.
    clients: Table[string, ModuleClient]

proc getLibExtension(): string =
  when defined(macosx): ".dylib"
  elif defined(windows): ".dll"
  else: ".so"

proc resolveDefaultPaths(): tuple[libPath: string, modulesDir: string, logosHost: string] =
  let coreBuild = getCurrentDir() / "core" / "build"
  let exeExt = when defined(windows): ".exe" else: ""
  result = (absolutePath(coreBuild / "lib" / ("liblogos_core" & getLibExtension())),
            absolutePath(coreBuild / "modules"),
            absolutePath(coreBuild / "bin" / ("logos_host" & exeExt)))

# ---------------------------------------------------------------------------
# Legacy parameter encoding. lp_invoke takes a plain JSON array of values;
# `logos_client.legacyParamsToArgs` converts this shape to one.
# ---------------------------------------------------------------------------

proc toJson*(params: openArray[Param]): string =
  var parts: seq[string] = @[]
  for p in params:
    parts.add("{\"name\":\"" & p.name & "\",\"value\":\"" & p.value &
              "\",\"type\":\"" & p.ptype & "\"}")
  result = "[" & parts.join(",") & "]"

proc inferParams*(values: openArray[string]): string =
  var params: seq[Param] = @[]
  for i, v in values:
    params.add(Param(name: "arg" & $i, value: v, ptype: "string"))
  result = toJson(params)

# ---------------------------------------------------------------------------
# Runtime half
# ---------------------------------------------------------------------------

proc requireSym[T](handle: LibHandle, name: string): T =
  let p = symAddr(handle, name)
  if p.isNil:
    quit &"Required symbol not found in liblogos_core: {name}", QuitFailure
  cast[T](p)

proc loadLibrary(self: LogosAPI) =
  self.lib = loadLib(self.libPath)
  if self.lib.isNil:
    quit &"Failed to load library: {self.libPath}", QuitFailure

  template need(field, name: untyped) =
    self.field = requireSym[typeof(self.field)](self.lib, name)

  # These are the CURRENT names. The pre-extraction API this SDK used to bind
  # (logos_core_set_plugins_dir / _process_plugin / _load_plugin /
  # _get_loaded_plugins / _call_plugin_method_async / _register_event_listener /
  # _exec / _process_events) no longer exists in liblogos_core — the plugin→
  # module rename took the first four and the protocol extraction took the rest.
  need(p_init, "logos_core_init")
  need(p_add_modules_dir, "logos_core_add_modules_dir")
  need(p_start, "logos_core_start")
  need(p_cleanup, "logos_core_cleanup")
  need(p_get_loaded_modules, "logos_core_get_loaded_modules")
  need(p_get_known_modules, "logos_core_get_known_modules")
  need(p_process_module, "logos_core_process_module")
  need(p_load_module, "logos_core_load_module")
  need(p_unload_module, "logos_core_unload_module")
  need(p_get_modules_info, "logos_core_get_modules_info")
  need(p_get_token, "logos_core_get_token")
  need(p_set_module_transports, "logos_core_set_module_transports")
  need(p_set_persistence_base_path, "logos_core_set_persistence_base_path")
  need(p_refresh_modules, "logos_core_refresh_modules")

proc convertCStringArray(ptrArr: ptr cstring): seq[string] =
  result = @[]
  if ptrArr.isNil: return
  let arr = cast[ptr UncheckedArray[cstring]](ptrArr)
  var i = 0
  while arr[i] != nil:
    result.add($arr[i])
    inc i

proc takeCoreString(s: cstring): string =
  ## Copy a `logos_core_*` return string, which the header documents as
  ## caller-owned.
  ##
  ## Deliberately NOT freed. liblogos allocates these with `new char[]`
  ## (logos_core.cpp / module_manager.cpp), and the only deallocator a C ABI
  ## offers a foreign-language caller is `free()`. Pairing `free()` with
  ## `new[]` is undefined behaviour, so this leaks the copy rather than risk a
  ## heap corruption that would surface far from its cause. The strings are
  ## small and these calls are not hot paths; the real fix is upstream —
  ## liblogos should allocate with `malloc` (or export a matching free).
  if s.isNil: return ""
  result = $s

proc logosInit*(self: LogosAPI): bool

proc newLogosAPI*(libPath = "", modulesDir = "", autoInit = true,
                  originModule = "core"): LogosAPI =
  let paths = resolveDefaultPaths()
  result = LogosAPI(
    libPath: (if libPath.len > 0: libPath else: paths.libPath),
    modulesDirs: @[(if modulesDir.len > 0: modulesDir else: paths.modulesDir)],
    isInitialized: false,
    isStarted: false,
    originModule: originModule,
    transports: initTable[string, string](),
    clients: initTable[string, ModuleClient]()
  )
  # Only derive LOGOS_HOST_PATH when the caller has not already set one. The
  # derivation is cwd-relative (./core/build/bin/logos_host) and wrong for
  # every packaged layout, so overwriting an explicit setting broke exactly
  # the deployments that had got it right.
  if getEnv("LOGOS_HOST_PATH").len == 0:
    putEnv("LOGOS_HOST_PATH", paths.logosHost)
  if autoInit:
    discard result.logosInit()

proc addModulesDir*(self: LogosAPI, dir: string) =
  ## Add another module search directory. Must be called before `start`
  ## (or followed by `refreshModules`).
  if dir.len == 0: return
  if dir notin self.modulesDirs: self.modulesDirs.add dir
  if self.isInitialized: self.p_add_modules_dir(dir.cstring)

proc logosInit*(self: LogosAPI): bool =
  if self.isInitialized: return true
  if not fileExists(self.libPath):
    quit &"Library file not found at {self.libPath}", QuitFailure
  self.loadLibrary()
  self.p_init(0, nil)
  for d in self.modulesDirs:
    if d.len > 0: self.p_add_modules_dir(d.cstring)
  self.isInitialized = true
  result = true

proc setPersistenceBasePath*(self: LogosAPI, path: string) =
  ## Where module instances keep their state. Must precede `start`.
  if not self.isInitialized: discard self.logosInit()
  self.p_set_persistence_base_path(path.cstring)

proc setModuleTransport*(self: LogosAPI, moduleName, transportJson: string) =
  ## Bind `moduleName` to a specific transport, and dial the SAME endpoint
  ## from this process's consumer clients.
  ##
  ## This is what makes a Qt-free Nim process possible: the default transport
  ## is Qt-affine (QLocalSocket + Qt Remote Objects) and needs a Qt event loop
  ## in the consumer, while a plain `tcp` transport needs none. Pass e.g.
  ## `tcpTransport("127.0.0.1", 6001)`.
  ##
  ## Ordering, straight from the C API's contract: this must run BEFORE the
  ## module is loaded — for `capability_module` that means before `start`.
  if not self.isInitialized: discard self.logosInit()
  self.transports[moduleName] = transportJson
  # The loader takes a transport SET (a JSON array of transport configs).
  let s = transportJson.strip()
  let setJson = if s.startsWith("["): s else: "[" & s & "]"
  self.p_set_module_transports(moduleName.cstring, setJson.cstring)

proc start*(self: LogosAPI): bool =
  ## Discover installed modules and bring `capability_module` up.
  if not self.isInitialized: discard self.logosInit()
  if self.isStarted: return true
  self.p_start()
  self.isStarted = true
  result = true

proc getLoadedModules*(self: LogosAPI): seq[string] =
  convertCStringArray(self.p_get_loaded_modules())

proc getKnownModules*(self: LogosAPI): seq[string] =
  convertCStringArray(self.p_get_known_modules())

proc getModuleStatus*(self: LogosAPI): tuple[loaded: seq[string], known: seq[string]] =
  (self.getLoadedModules(), self.getKnownModules())

proc getModulesInfo*(self: LogosAPI): JsonNode =
  ## Everything the core knows about every module, as JSON.
  let s = takeCoreString(self.p_get_modules_info())
  if s.len == 0: newJArray() else: parseJson(s)

proc refreshModules*(self: LogosAPI) =
  ## Re-scan the module directories (call after installing new modules).
  self.p_refresh_modules()

proc processModule*(self: LogosAPI, modulePath: string): string =
  ## Register a module binary by PATH; returns its name ("" on failure).
  takeCoreString(self.p_process_module(modulePath.cstring))

proc loadModule*(self: LogosAPI, moduleName: string,
                 withDependencies = true): bool =
  ## Ensure `moduleName` is loaded. Idempotent: already-loaded is success.
  self.p_load_module(moduleName.cstring, withDependencies) == 1

proc unloadModule*(self: LogosAPI, moduleName: string,
                   withDependents = false): bool =
  self.p_unload_module(moduleName.cstring, withDependents) == 1

proc loadModules*(self: LogosAPI, moduleNames: openArray[string]):
    seq[tuple[name: string, loaded: bool]] =
  for name in moduleNames:
    result.add((name: name, loaded: self.loadModule(name)))

proc coreToken*(self: LogosAPI, key: string): string =
  ## The token the embedded core holds for `key` ("" when it holds none).
  if not self.isInitialized: return ""
  takeCoreString(self.p_get_token(key.cstring))

# ---------------------------------------------------------------------------
# Consumer half — lp_* from here down.
# ---------------------------------------------------------------------------

proc ensureProtocol(self: LogosAPI) =
  ## Bind the shared logos-protocol library.
  ##
  ## It is looked for next to liblogos_core first (an embedded-core layout
  ## ships both in one `lib/`), then LOGOS_PROTOCOL_LIB, then the loader's own
  ## paths. liblogos_core links the STATIC protocol archive and re-exports no
  ## `lp_*` symbol — measured: zero on macOS — so the shared build has to be
  ## loaded in its own right.
  if lp.isProtocolLoaded(): return
  let hint = self.libPath.parentDir / (lp.libBaseName() & lp.libExtension())
  lp.loadProtocol(if fileExists(hint): hint else: "")

proc bridgeToken(self: LogosAPI, moduleName: string) =
  ## Hand the core's token for `moduleName` to the protocol image.
  ##
  ## The two are SEPARATE images — liblogos_core links the protocol archive
  ## statically while this SDK dlopens the shared build — so they have
  ## separate TokenManagers, and the one this SDK calls through starts empty.
  ## Without this, the client falls back to the `requestModule` handshake and
  ## capability_module refuses it: its known-caller gate only recognises
  ## identities it has been handed a token for, which an embedder process is
  ## not and cannot become by asserting a name.
  ##
  ## The embedder is entitled to these tokens — it is the process that minted
  ## them — so copying them across the image boundary grants nothing new; it
  ## just makes the second copy of the token store agree with the first.
  if moduleName.len == 0: return
  if lp.tokenGet(moduleName).len > 0: return
  let tok = self.coreToken(moduleName)
  if tok.len > 0: lp.tokenSave(moduleName, tok)

proc client*(self: LogosAPI, moduleName: string): ModuleClient =
  ## The (cached) lp_* consumer client for `moduleName`, dialing whatever
  ## transport the module was registered with.
  if self.clients.hasKey(moduleName):
    return self.clients[moduleName]
  self.ensureProtocol()
  self.bridgeToken("capability_module")
  self.bridgeToken(moduleName)
  let target = self.transports.getOrDefault(moduleName, "")
  let capability = self.transports.getOrDefault("capability_module", target)
  result = newModuleClient(moduleName, self.originModule, target, capability)
  self.clients[moduleName] = result

proc closeClients*(self: LogosAPI) =
  for _, c in self.clients: c.close()
  self.clients.clear()

proc cleanup*(self: LogosAPI) =
  # Consumer clients first: lp_client_destroy has to run while the transport
  # is still alive, otherwise a deferred teardown never executes.
  self.closeClients()
  if self.lib != nil and not self.p_cleanup.isNil:
    self.p_cleanup()
  if self.lib != nil:
    unloadLib(self.lib)
    self.lib = nil
  self.isInitialized = false
  self.isStarted = false

proc jsonToMessage(n: JsonNode): string =
  ## Historical callback-message semantics: a string result arrives unquoted,
  ## null arrives empty, anything else arrives as compact JSON. Matches what
  ## logos-module-client's C facade does for the other FFI SDKs, so callers
  ## that parse these messages do not have to change.
  if n.isNil: return ""
  case n.kind
  of JNull: ""
  of JString: n.getStr()
  else: $n

proc callModuleMethodAsync*(self: LogosAPI, moduleName, methodName,
                            paramsJson: string, cb: LogosCallback) =
  ## Asynchronous cross-module call. `paramsJson` accepts either the legacy
  ## `[{name,value,type}]` shape or a plain JSON array of values.
  ##
  ## The callback is delivered from `poll` / `processEventsTick`, on the
  ## calling thread — never on the protocol's internal thread.
  let m = self.client(moduleName)
  var args: JsonNode
  try:
    args = legacyParamsToArgs(paramsJson)
  except ValueError as e:
    if not cb.isNil: cb(false, e.msg)
    return
  let handler = proc (o: CallOutcome) =
    if cb.isNil: return
    if o.ok: cb(true, jsonToMessage(o.value))
    else: cb(false, o.message)
  try:
    m.invokeAsync(methodName, args, 0, handler)
  except CatchableError as e:
    if not cb.isNil: cb(false, e.msg)

proc callPluginMethodAsync*(self: LogosAPI, pluginName, methodName,
                            paramsJson: string, cb: LogosCallback) =
  ## Back-compat alias for `callModuleMethodAsync` (plugins are modules).
  self.callModuleMethodAsync(pluginName, methodName, paramsJson, cb)

proc registerEventListener*(self: LogosAPI, moduleName, eventName: string,
                            cb: LogosCallback) =
  ## Subscribe to `moduleName`'s `eventName`. The payload reaches `cb` as the
  ## JSON array the ABI delivers.
  ##
  ## The module does not have to be loaded yet — the subscription is held and
  ## armed when it appears.
  let m = self.client(moduleName)
  let handler = proc (name: string, payload: JsonNode) =
    if not cb.isNil: cb(true, $payload)
  try:
    discard m.subscribe(eventName, handler)
  except CatchableError as e:
    if not cb.isNil: cb(false, e.msg)

proc processEventsTick*(self: LogosAPI) =
  ## Deliver whatever the consumer plane has queued. Kept under its old name
  ## because callers pump in a loop; the core no longer has an event pump of
  ## its own (`logos_core_process_events` was removed with the extraction) and
  ## needs none — module hosts are separate processes.
  discard poll()

proc module*(self: LogosAPI, name: string): PluginProxy =
  PluginProxy(api: self, name: name)

proc plugin*(self: LogosAPI, name: string): PluginProxy =
  ## Back-compat alias for `module`.
  PluginProxy(api: self, name: name)

proc call*(p: PluginProxy, methodName: string, paramsJsonOrValue: string,
           cb: LogosCallback) =
  # A string that already looks like a JSON array is the full params JSON and
  # passes through; anything else is a single string argument.
  let s = paramsJsonOrValue.strip()
  if s.len > 0 and s[0] == '[':
    p.api.callModuleMethodAsync(p.name, methodName, s, cb)
  else:
    p.api.callModuleMethodAsync(p.name, methodName,
                                inferParams([paramsJsonOrValue]), cb)

proc callStrings*(p: PluginProxy, methodName: string,
                  values: openArray[string], cb: LogosCallback) =
  p.call(methodName, inferParams(values), cb)

proc on*(p: PluginProxy, eventName: string, cb: LogosCallback) =
  p.api.registerEventListener(p.name, eventName, cb)

proc invoke*(p: PluginProxy, methodName: string, args: JsonNode = nil,
             timeoutMs = 0): JsonNode =
  ## Blocking cross-module call returning the parsed result JSON value.
  ## Raises `LogosCallError` when the call fails structurally.
  p.api.client(p.name).invoke(methodName, args, timeoutMs)

proc tryInvoke*(p: PluginProxy, methodName: string, args: JsonNode = nil,
                timeoutMs = 0): CallOutcome =
  ## Non-raising twin of `invoke`.
  p.api.client(p.name).tryInvoke(methodName, args, timeoutMs)

proc subscribe*(p: PluginProxy, eventName: string,
                handler: EventHandler): Subscription =
  ## Typed event subscription; payloads arrive as JSON from `poll`.
  p.api.client(p.name).subscribe(eventName, handler)
