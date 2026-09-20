# Package
version       = "0.2.0"
author        = "Logos"
description   = "Nim SDK for Logos Core: call modules, and be one"
license       = "MIT or Apache License 2.0"
srcDir        = "."

# The consumer half (logos_api.nim) drives liblogos_core and needs nothing but
# the stdlib. The provider half (sdk/) implements the module ABI a Logos host
# loads, and leans on nim-ffi for the FFI machinery rather than restating it.
requires "nim >= 2.0.0"
requires "https://github.com/logos-messaging/nim-ffi >= 0.3.0"

task test, "Run the SDK test suite":
  for t in ["test_bytes", "test_wire", "test_lidl_text"]:
    exec "nim c -r --hints:off --path:. -o:/tmp/lns_" & t & " tests/" & t & ".nim"
