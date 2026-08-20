# logos-nim-sdk

Nim SDK for [Logos](https://github.com/logos-co). A Nim program can **consume**
Logos modules — call their methods, subscribe to their events — and optionally
**embed** a Logos core that loads those modules in the first place.

The consumer surface is protocol-native: it binds the language-neutral `lp_*`
C ABI of [logos-protocol](https://github.com/logos-co/logos-protocol), the same
seam the Rust and JS SDKs use. Nothing here needs Qt.

## Layout

| File | What it is |
|---|---|
| `logos_protocol.nim` | Raw bindings for the `lp_*` C ABI, bound at run time out of the shared `liblogos_protocol` |
| `logos_client.nim` | The consumer API: clients, `invoke`, `invokeAsync`, `subscribe`, transports, the delivery pump |
| `logos_api.nim` | The above plus an embedded core (`liblogos_core`): discover, load and unload modules |

A consumer that talks to an already-running Logos deployment needs only
`logos_client`. Import `logos_api` when this process should also host the core.

## Consuming a module

```nim
import logos_client
import std/json

# Dial a module over a plain TCP transport — no Qt event loop anywhere.
let logos = newLogosClient("my_app", tcpTransport("127.0.0.1", 6001))
let calc = logos.module("calc_module")

echo calc.invoke("add", %*[5, 3]).getInt()          # blocking, raises on failure

let outcome = calc.tryInvoke("add", %*[5, 3])       # non-raising twin
if not outcome.ok:
  echo outcome.code, ": ", outcome.message          # canonical error object

# Async results and events are delivered on YOUR thread, from poll().
calc.invokeAsync("add", %*[1, 2], handler = proc (o: CallOutcome) =
  echo "async: ", o.value)

let sub = calc.subscribe("computed", proc (name: string, payload: JsonNode) =
  echo name, " -> ", payload)

discard pollFor(2000)     # pump for 2s
sub.cancel()
logos.close()
```

Transports: `localTransport()` (Qt-affine — needs a Qt event loop in this
process), `tcpTransport(host, port)` and `tcpSslTransport(...)` (Qt-free).
Omit the transport to use the process default.

Binary data crosses the ABI inside JSON as `{"_bytes": "<base64url>"}`;
`bytesArg` / `bytesValue` build and read that envelope.

## Embedding a core

```nim
import logos_api
import std/json

let api = newLogosAPI(libPath = "/path/to/liblogos_core.dylib",
                      modulesDir = "/path/to/modules",
                      originModule = "my_app")

# Put both modules on a plain transport BEFORE they load — this is what keeps
# the process Qt-free. capability_module loads inside start().
api.setModuleTransport("capability_module", tcpTransport("127.0.0.1", 6002))
api.setModuleTransport("calc_module", tcpTransport("127.0.0.1", 6001))

discard api.start()
discard api.loadModule("calc_module")

echo api.module("calc_module").invoke("add", %*[5, 3]).getInt()

api.processEventsTick()   # deliver queued async results / events
api.cleanup()
```

`LOGOS_HOST_PATH` must point at the `logos_host` binary. The shared
logos-protocol library is looked for next to `liblogos_core` first, then at
`$LOGOS_PROTOCOL_LIB`, then on the loader's own search path.

### Why the shared logos-protocol library is a separate artifact

`liblogos_core` links the **static** protocol archive and re-exports no `lp_*`
symbol, so the SDK loads `liblogos_protocol.{dylib,so,dll}` itself. That means
an embedded-core process holds two copies of logos-protocol, each with its own
token store. Two consequences the SDK handles for you:

* **They must be the same build.** Qt's `QMetaType` registry is process-global,
  and both copies register the same type names. An independently-pinned shared
  library — same MAJOR.MINOR, different revision — crashed the end-to-end check
  with a SIGSEGV on the first call. `flake.nix` therefore makes
  `logos-liblogos` follow this flake's `logos-protocol`.
* **Tokens have to cross.** `LogosAPI.client` copies the core's token for the
  target (and for `capability_module`) into the protocol image before the first
  call. Without that the client falls back to the `requestModule` handshake and
  `capability_module` refuses it: its known-caller gate only recognises
  identities it has been handed a token for, which an embedder process is not.

## Building and testing

```bash
nix build                 # source + liblogos_core + liblogos_protocol + logos_host
nix develop               # nim, with every LOGOS_* variable already exported
nix flake check           # both checks below

nix build '.#checks.<system>.protocol-abi'    # hermetic: protocol library only
nix build '.#checks.<system>.embedded-e2e'    # embedded core + a real module
```

`tests/test_protocol_abi.nim` needs nothing but the shared protocol library.
`tests/test_embedded_e2e.nim` stands up a real `test_basic_module` in its own
`logos_host` process over plain TCP and drives every consumer path against it.

## Migrating from the pre-protocol SDK

The old SDK reached modules through `logos_core_call_plugin_method_async` and
`logos_core_register_event_listener`. Those C entry points no longer exist —
the protocol extraction removed them from `liblogos_core` — and the
plugin→module rename took `logos_core_set_plugins_dir`, `_process_plugin`,
`_load_plugin` and `_get_loaded_plugins` with it, so the old code could not
even load the library.

| Was | Now |
|---|---|
| `newLogosAPI(pluginsDir = …)` | `newLogosAPI(modulesDir = …)` |
| `api.processPlugin(name)` | `api.processModule(path)` (takes a PATH, returns the name) |
| `api.loadPlugin(name)` | `api.loadModule(name, withDependencies = true)` |
| `api.unloadPlugin(name)` | `api.unloadModule(name, withDependents = false)` |
| `api.processAndLoadPlugins(names)` | `api.loadModules(names)` |
| `api.getLoadedPlugins()` | `api.getLoadedModules()` |
| `api.getKnownPlugins()` | `api.getKnownModules()` |
| `api.exec()` | removed — module hosts are separate processes; there is no in-process loop to run |
| `api.processEventsTick()` | kept; now drains the consumer delivery queue |
| `api.plugin(n)` / `.call` / `.on` | kept (`api.module(n)` is the new spelling), now over `lp_*` |
| `api.callPluginMethodAsync(...)` | kept as an alias for `callModuleMethodAsync`, now over `lp_invoke_async` |

`Param` / `toJson` / `inferParams` and the `[{name,value,type}]` parameter shape
still work: `legacyParamsToArgs` converts them to the plain JSON argument array
`lp_invoke` takes, with the same coercions the C facade applies for the other
FFI SDKs.
