## `{.logosEvent.}` — declare an event, get a typed emitter.
##
## An event is a bodiless proc. The macro writes the body: build the positional
## array the ABI expects and hand it to the host's callback.
##
##     proc deliveryProgress(opId, state: string) {.logosEvent.}
##     proc inbound(topic, sender: string, blob: seq[byte]) {.logosEvent.}
##
##     deliveryProgress(opId, "queued")     # typed; no stringly-typed name
##
## It also records the event's shape, which is the half `{.dispatchMethod.}`
## cannot see: `logos_module_get_methods` has to describe events as well as
## methods, and nothing else knows they exist.
import std/[json, macros, strutils]
import ./bytes

var logosEventMeta* {.compileTime.}: seq[(string, seq[(string, string)], string)] = @[]
  ## (wireName, [(paramName, nimType)], doc), in declaration order.

proc camelToSnakeEvent(s: string): string {.compileTime.} =
  var r = ""
  for i, c in s:
    if c in {'A' .. 'Z'}:
      if i > 0: r.add('_')
      r.add(chr(ord(c) + 32))
    else: r.add(c)
  return r

proc firstDoc(p: NimNode): string {.compileTime.} =
  let body = p.body
  if body.kind == nnkStmtList and body.len > 0 and body[0].kind == nnkCommentStmt:
    for line in body[0].strVal.splitLines():
      let t = line.strip()
      if t.len > 0: return t
  return ""

proc buildEvent(wire: string, p: NimNode): NimNode {.compileTime.} =
  let doc = firstDoc(p)
  # The pragma comes off, or it is applied to our own output and recurses.
  var keep = nnkPragma.newTree()
  if p.pragma.kind == nnkPragma:
    for prag in p.pragma:
      let n = if prag.kind in {nnkExprColonExpr, nnkCall} and prag.len > 0: $prag[0]
              elif prag.kind == nnkIdent: $prag
              else: ""
      if n notin ["logosEvent", "logosEventAs"]: keep.add(prag)
  p.pragma = (if keep.len == 0: newEmptyNode() else: keep)

  let params = p.params
  var meta: seq[(string, string)] = @[]
  let argsId = genSym(nskVar, "evArgs")
  var body = newStmtList()
  body.add quote do:
    var `argsId` = newJArray()

  for i in 1 ..< params.len:
    let group = params[i]
    let tn = group[^2].repr.strip()
    for j in 0 ..< group.len - 2:
      let pid = group[j]
      meta.add(($pid, tn))
      if tn == "seq[byte]":
        body.add quote do:
          `argsId`.add(toLogosBytes(`pid`))
      else:
        body.add quote do:
          `argsId`.add(%(`pid`))

  let wireLit = newLit(wire)
  body.add quote do:
    emitEvent(`wireLit`, `argsId`)

  p.body = body
  logosEventMeta.add((wire, meta, doc))
  return p

macro logosEvent*(p: untyped): untyped =
  ## Wire name from the proc name, in snake_case.
  return buildEvent(camelToSnakeEvent($p.name), p)

macro logosEventAs*(nameLit: static[string], p: untyped): untyped =
  ## Explicit wire name. A separate pragma rather than an overload -- an
  ## overloaded macro cannot be used as a pragma.
  return buildEvent(nameLit, p)

macro logosEventMetaSeq*(): untyped =
  ## The recorded shapes, for the manifest.
  var arr = nnkBracket.newTree()
  for (wire, params, doc) in logosEventMeta:
    var pArr = nnkBracket.newTree()
    for (pn, pt) in params:
      pArr.add nnkTupleConstr.newTree(newLit(pn), newLit(pt))
    let pSeq = nnkPrefix.newTree(ident("@"),
      (if params.len == 0: nnkBracket.newTree() else: pArr))
    arr.add nnkTupleConstr.newTree(newLit(wire), pSeq, newLit(doc))
  if logosEventMeta.len == 0:
    # a module with no events of its own: the empty seq still needs a type
    return quote do:
      newSeq[(string, seq[(string, string)], string)]()
  result = nnkPrefix.newTree(ident("@"), arr)
