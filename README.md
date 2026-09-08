# logos-nim-sdk

Nim SDK for Logos Core, providing Nim bindings to interact with the Logos Core system.

> **Status: unmaintained, and pinned to a pre-rename Logos Core.**
>
> `flake.lock` pins logos-liblogos at `5030aaaf` (2026-03-16), and the bindings
> match that revision: `nix build` still works, because it builds against the
> pinned liblogos rather than a current one.
>
> It will NOT work against a current liblogos. Logos Core has since renamed its
> module-management C API from "plugin" to "module", and 10 of the 13 symbols
> this SDK resolves no longer exist — only `logos_core_init`,
> `logos_core_start` and `logos_core_cleanup` survive. Because `logos_api.nim`
> resolves every symbol eagerly through `requireSym` at `newLogosAPI()`, the
> mismatch is a hard `quit` at startup, not a per-call failure.
>
> The load entry point is the clearest example: `logos_core_load_plugin(name)`
> became `logos_core_load_module(name, deps)`, where `deps` is a `LogosLoadDeps`
> (`LOGOS_LOAD_MODULE_ONLY` / `LOGOS_LOAD_REQUIRED_DEPS` /
> `LOGOS_LOAD_REQUIRED_AND_OPTIONAL`).
>
> Retargeting this SDK means rewriting the binding table against a current
> `logos_core.h`, not renaming a symbol. For a maintained non-C++ binding, see
> logos-js-sdk, which was rebuilt on the protocol-native `lp_*` C ABI.

## Building with Nix

This SDK uses Nix to automatically fetch and bundle `logos-liblogos`:

```bash
# Build the SDK with logos-liblogos included
nix build

# The result will be in ./result/ with:
# - logos_api.nim (the SDK)
# - lib/ (containing liblogos_core shared library)
# - bin/ (containing logos_host binary if available)
```

## Development Environment

Enter a development shell with Nim and other dependencies:

```bash
nix develop
```

## Usage

The SDK provides a `LogosAPI` object that loads and interacts with the Logos Core library:

```nim
import logos_api

# Create API instance (will auto-detect library and plugins from build directory)
let api = newLogosAPI()

# Or specify custom paths
let api = newLogosAPI(
  libPath = "./lib/liblogos_core.dylib",
  pluginsDir = "./plugins"
)

# Load and use plugins
discard api.processAndLoadPlugins(["simple_module"])
```

See the Logos Core documentation for more examples and usage patterns.
