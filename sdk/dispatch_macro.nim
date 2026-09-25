## `{.dispatchMethod.}` — turn an ordinary Nim proc into a routed handler.
##
## The proc is left exactly as written and callable as normal Nim. Alongside it
## the macro emits a wrapper that decodes a positional JSON array into the
## proc's parameters, checks arity and types, calls it, and encodes the result.
## `dispatchTableFor()` then collects the wrappers into a table.
##
##     proc subscribe(topic: string): bool {.dispatchMethod.} = ...
##     proc sendIt(topic: string): string {.dispatchAs: "send".} = ...
##
##     let table = dispatchTableFor()   # last, after every annotation
##
## The wire name is the proc name in snake_case (`deliveryProgress` ->
## `delivery_progress`), or given explicitly with `{.dispatchAs: "send".}`.
##
## Parameter types supported are the ones that cross a JSON boundary without
## ambiguity: string, the integer types, float, bool, and seq[byte]. JSON has
## no bytes, so `seq[byte]` goes through Logos's `{"_bytes":"<base64url>"}`
## convention in `./bytes` -- at every depth, because a plain encode would emit
## an array of numbers that no other language decodes as bytes.
import std/[json, macros, strutils, tables]
import ./dispatch
import ./bytes

export dispatch

proc camelToSnake*(s: string): string =
  ## LIDL spells method and event names in snake_case; Nim spells procs in
  ## camelCase. This is the one place the two meet, and `{.dispatchAs.}` is the
  ## escape hatch for a wire name that is not simply the proc name.
  var r = ""
  for i, c in s:
    if c in {'A' .. 'Z'}:
      if i > 0: r.add('_')
      r.add(chr(ord(c) + 32))
    else: r.add(c)
  return r

var dispatchRegistry {.compileTime.}: seq[(string, NimNode)] = @[]
  ## (wireName, wrapperSymbol), in declaration order.

var dispatchMeta {.compileTime.}: seq[(string, string, seq[(string, string)],
                                       string, string)] = @[]
  ## (wireName, procName, [(paramName, nimType)], returnType, doc).
  ##
  ## Kept alongside rather than inside the handler, because an ABI needs this
  ## at COMPILE time to emit a manifest, while the handler is a runtime value.

proc jsonCheckFor(kind: string): string =
  ## The type name reported in "expected X at argN".
  case kind
  of "string": "string"
  of "int", "int64", "uint64", "uint": "integer"
  of "float", "float64": "number"
  of "bool": "boolean"
  of "seq[byte]": "bytes"
  else: kind

proc stripDispatchPragma(p: NimNode) {.compileTime.} =
  ## The pragma has to come off the proc we hand back, or it is applied again
  ## to our own output and expands forever.
  let pragmas = p.pragma
  if pragmas.kind != nnkPragma: return
  var keep = nnkPragma.newTree()
  for prag in pragmas:
    let name =
      if prag.kind in {nnkExprColonExpr, nnkCall} and prag.len > 0: $prag[0]
      elif prag.kind == nnkIdent: $prag
      else: ""
    if name notin ["dispatchMethod", "dispatchAs"]: keep.add(prag)
  p.pragma = (if keep.len == 0: newEmptyNode() else: keep)

proc firstDocLine(p: NimNode): string {.compileTime.} =
  ## A proc's doc comment is the first statement of its body. Manifests want
  ## one line, so that is what is taken.
  let body = p.body
  if body.kind == nnkStmtList and body.len > 0 and body[0].kind == nnkCommentStmt:
    let full = body[0].strVal
    for line in full.splitLines():
      let t = line.strip()
      if t.len > 0: return t
  return ""

proc buildDispatch(nameLit: string, p: NimNode): NimNode {.compileTime.} =
  let docLine = firstDocLine(p)
  stripDispatchPragma(p)
  result = newStmtList(p)
  let procName = $p.name
  let wrapper = genSym(nskProc, procName & "DispatchWrapper")
  let params = p.params
  var arity = 0
  for i in 1 ..< params.len:
    arity += params[i].len - 2

  # Build: proc wrapper(args: JsonNode): DispatchResult = ...
  let argsId = ident("args")
  var body = newStmtList()
  body.add quote do:
    if `argsId`.len != `arity`:
      return failArity(`nameLit`, `arity`, `argsId`.len)

  var callArgs = newSeq[NimNode]()
  var idx = 0
  for i in 1 ..< params.len:
    let group = params[i]
    let typeNode = group[^2]
    let typeStr = typeNode.repr.strip()
    for j in 0 ..< group.len - 2:
      let at = newLit(idx)
      let want = newLit(jsonCheckFor(typeStr))
      let tmp = genSym(nskLet, "a" & $idx)
      case typeStr
      of "string":
        body.add quote do:
          if `argsId`[`at`].kind != JString:
            return failArgType(`nameLit`, `at`, `want`, `argsId`[`at`])
        body.add quote do:
          let `tmp` = `argsId`[`at`].getStr()
      of "bool":
        body.add quote do:
          if `argsId`[`at`].kind != JBool:
            return failArgType(`nameLit`, `at`, `want`, `argsId`[`at`])
        body.add quote do:
          let `tmp` = `argsId`[`at`].getBool()
      of "int", "int64":
        body.add quote do:
          if `argsId`[`at`].kind != JInt:
            return failArgType(`nameLit`, `at`, `want`, `argsId`[`at`])
        body.add quote do:
          let `tmp` = `argsId`[`at`].getInt()
      of "float", "float64":
        body.add quote do:
          if `argsId`[`at`].kind notin {JInt, JFloat}:
            return failArgType(`nameLit`, `at`, `want`, `argsId`[`at`])
        body.add quote do:
          let `tmp` = `argsId`[`at`].getFloat()
      of "seq[byte]":
        # No kind check: the ABI's decoder decides what it accepts, and most
        # accept several shapes for parity with their C++ and Rust siblings.
        body.add quote do:
          let `tmp` = fromLogosBytes(`argsId`[`at`])
      else:
        error("dispatchMethod: parameter type '" & typeStr &
              "' does not cross a JSON boundary unambiguously", p)
      callArgs.add(tmp)
      inc idx

  let callee = p.name
  var call = newCall(callee)
  for a in callArgs: call.add(a)

  let retStr = (if params[0].kind == nnkEmpty: "" else: params[0].repr.strip())
  # The handler is ordinary module code and may raise anything -- a C
  # callback it invokes has no declared effects, so Nim assumes bare
  # Exception. The wrapper is the boundary, so it catches all of it; the
  # boundary, so it catches. Requiring every handler to be `raises: []` would
  # push that obligation onto authors for no gain -- the call still cannot be
  # allowed to escape either way.
  if retStr == "" or retStr == "void":
    body.add quote do:
      try:
        `call`
        return ok(newJNull())
      except Exception as e:
        return failRaised(`nameLit`, e.msg)
  elif retStr == "seq[byte]":
    body.add quote do:
      try:
        let r = `call`
        return ok(toLogosBytes(r))
      except Exception as e:
        return failRaised(`nameLit`, e.msg)
  else:
    body.add quote do:
      try:
        return ok(%(`call`))
      except Exception as e:
        return failRaised(`nameLit`, e.msg)

  result.add newProc(
    name = wrapper,
    params = [ident("DispatchResult"), newIdentDefs(argsId, ident("JsonNode"))],
    body = body,
    pragmas = nnkPragma.newTree(
      nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree())))

  var metaParams: seq[(string, string)] = @[]
  for i in 1 ..< params.len:
    let group = params[i]
    let tn = group[^2].repr.strip()
    for j in 0 ..< group.len - 2:
      metaParams.add(($group[j], tn))
  dispatchMeta.add((nameLit, $p.name, metaParams, retStr, docLine))

  dispatchRegistry.add((nameLit, wrapper))
  return result

macro dispatchMethod*(p: untyped): untyped =
  ## Wire name derived from the proc name, in snake_case.
  return buildDispatch(camelToSnake($p.name), p)

macro dispatchAs*(nameLit: static[string], p: untyped): untyped =
  ## Explicit wire name: `{.dispatchAs: "send".}`.
  ##
  ## A separate name rather than an overload of `dispatchMethod`, because an
  ## OVERLOADED macro cannot be used as a pragma -- Nim resolves the pragma but
  ## then keeps the original routine as well, and the error it gives you is
  ## "redefinition of <your proc>" pointing at the proc's own line.
  return buildDispatch(nameLit, p)

macro dispatchTableFor*(): untyped =
  ## Terminal: collects every `{.dispatchMethod.}` in this module. Must come
  ## after all of them, for the same reason `genBindings()` must.
  let t = genSym(nskVar, "table")
  result = newStmtList()
  result.add quote do:
    var `t` = initTable[string, DispatchHandler]()
  for (wire, wrapper) in dispatchRegistry:
    let w = newLit(wire)
    result.add quote do:
      `t`.register(`w`, `wrapper`)
  result.add quote do:
    `t`

macro dispatchMethodNames*(): untyped =
  ## The wire names, in declaration order.
  var arr = nnkBracket.newTree()
  for (wire, _) in dispatchRegistry: arr.add(newLit(wire))
  result = nnkPrefix.newTree(ident("@"), arr)

macro dispatchMethodMeta*(): untyped =
  ## Every annotated proc's shape, in declaration order: what an ABI needs to
  ## emit an introspection manifest from the source rather than from a contract
  ## it would otherwise have to parse.
  var arr = nnkBracket.newTree()
  for (wire, procName, params, ret, doc) in dispatchMeta:
    var pArr = nnkBracket.newTree()
    for (pn, pt) in params:
      pArr.add nnkObjConstr.newTree(ident("DispatchParam"),
        nnkExprColonExpr.newTree(ident("name"), newLit(pn)),
        nnkExprColonExpr.newTree(ident("nimType"), newLit(pt)))
    let pSeq = (if params.len == 0:
                  nnkPrefix.newTree(ident("@"), nnkBracket.newTree())
                else: nnkPrefix.newTree(ident("@"), pArr))
    arr.add nnkObjConstr.newTree(ident("DispatchMethodMeta"),
      nnkExprColonExpr.newTree(ident("wireName"), newLit(wire)),
      nnkExprColonExpr.newTree(ident("procName"), newLit(procName)),
      nnkExprColonExpr.newTree(ident("params"), pSeq),
      nnkExprColonExpr.newTree(ident("returnType"), newLit(ret)),
      nnkExprColonExpr.newTree(ident("doc"), newLit(doc)))
  result = (if dispatchMeta.len == 0:
              nnkPrefix.newTree(ident("@"), nnkBracket.newTree())
            else: nnkPrefix.newTree(ident("@"), arr))
