# logos-nim-sdk

Nim SDK for Logos Core, providing Nim bindings to interact with the Logos Core system.

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
