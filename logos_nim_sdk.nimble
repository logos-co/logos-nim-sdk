# Package
version       = "0.2.0"
author        = "Logos"
description   = "Nim SDK for Logos Core: call modules, and be one"
license       = "MIT or Apache License 2.0"
srcDir        = "."

# Stdlib only, both halves. The consumer half (logos_api.nim) drives
# liblogos_core; the provider half (sdk/) implements the module ABI a Logos
# host loads. The single-entry-point dispatch profile lives here too: it was
# briefly a nim-ffi feature, but Logos is its only consumer and splitting one
# pragma across two packages bought nothing but a second repo to release.
requires "nim >= 2.0.0"

# Every tests/test_*.nim, so adding one does not mean remembering to list it
# here -- and so this task cannot name a file that is not there.
task test, "Run the SDK test suite":
  for f in listFiles("tests"):
    if f.endsWith(".nim"):
      exec "nim c -r --hints:off --path:. -o:/tmp/lns_test " & f
