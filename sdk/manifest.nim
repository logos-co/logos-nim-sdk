## Building `logos_module_get_methods` from the source.
##
## The Rust path emits this from the `.lidl`. Source-first, the same facts are
## already in the annotations -- parameter names, types, return types, doc
## comments -- so the manifest is generated rather than hand-maintained beside
## the code it describes.
##
## Two details that are not obvious and will not announce themselves if wrong:
##
##   * Keys are emitted in ALPHABETICAL order, because the Rust generator
##     serialises through a BTreeMap. A manifest with the same content in a
##     different key order is not byte-identical, and byte-identity is the only
##     way to know the two agree.
##   * `parameters` is OMITTED entirely for a method that takes none, rather
##     than emitted empty -- matching the introspector this schema imitates.
import std/[json, strutils, algorithm]
import ./wire

func snakeParam*(s: string): string =
  ## Nim spells parameters in camelCase, contracts in snake_case. The manifest
  ## must say what the contract says, or a consumer's generated client asks for
  ## a parameter the module does not report.
  var r = ""
  for i, c in s:
    if c in {'A' .. 'Z'}:
      if i > 0: r.add('_')
      r.add(chr(ord(c) + 32))
    else: r.add(c)
  return r

func nimTypeToLidl*(nimType: string): string =
  ## Nim's spelling of a type to the contract's. `metatypeName` maps from LIDL
  ## on to the wire, so this is the missing first half.
  case nimType
  of "string": "tstr"
  of "seq[byte]": "bstr"
  of "int", "int64": "int"
  of "uint", "uint64": "uint"
  of "float", "float64": "float64"
  of "bool": "bool"
  of "LogosResult": "result"
  of "JsonNode": "any"
  else: "any"

func qtForNim*(nimType: string): string =
  return metatypeName(nimTypeToLidl(nimType))

proc sortedObj(pairs: openArray[(string, JsonNode)]): JsonNode =
  ## An object with its keys in alphabetical order.
  var keys: seq[string] = @[]
  for (k, _) in pairs: keys.add(k)
  keys.sort()
  result = newJObject()
  for k in keys:
    for (kk, v) in pairs:
      if kk == k: result[k] = v; break

proc methodEntry*(wireName, doc: string, params: openArray[(string, string)],
                  returnNimType: string): JsonNode =
  var sigTypes: seq[string] = @[]
  var pArr = newJArray()
  for (pn, pt) in params:
    let qt = qtForNim(pt)
    sigTypes.add(qt)
    pArr.add(sortedObj({"name": %snakeParam(pn), "type": %qt}))

  var fields = @[
    ("description", %doc),
    ("isInvokable", %true),
    ("name", %wireName),
    ("returnType", %(if returnNimType.len == 0: "void" else: qtForNim(returnNimType))),
    ("signature", %(wireName & "(" & sigTypes.join(",") & ")")),
  ]
  # Omitted, not empty, when there are no parameters.
  if params.len > 0: fields.add(("parameters", pArr))
  return sortedObj(fields)

proc eventEntry*(wireName, doc: string,
                 params: openArray[(string, string)]): JsonNode =
  var sigTypes: seq[string] = @[]
  var pArr = newJArray()
  for (pn, pt) in params:
    let qt = qtForNim(pt)
    sigTypes.add(qt)
    pArr.add(sortedObj({"name": %snakeParam(pn), "type": %qt}))

  # No isInvokable and no returnType on an event: it is a signal, not a call.
  var fields = @[
    ("description", %doc),
    ("name", %wireName),
    ("signature", %(wireName & "(" & sigTypes.join(",") & ")")),
    ("type", %"event"),
  ]
  if params.len > 0: fields.add(("parameters", pArr))
  return sortedObj(fields)

proc identityEntries*(): seq[JsonNode] =
  ## `name`, `version` and `lidl` are derived built-ins: part of the contract
  ## for code generation, absent from the .lidl text, and present here because
  ## a host may call them. The descriptions are the generator's, verbatim.
  return @[
    methodEntry("name", "The module's name, as declared in its metadata.", [], "string"),
    methodEntry("version", "The module's version, as declared in its metadata.", [], "string"),
    methodEntry("lidl", "The module's canonical LIDL interface document.", [], "string"),
  ]
