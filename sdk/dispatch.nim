## Routing a named call to a Nim proc, synchronously.
##
## nim-ffi's usual shape is one exported C symbol per method, answered
## asynchronously on the library's own thread. Some plugin ABIs are the other
## shape entirely: a SINGLE entry point taking a method name and a payload, and
## returning the answer inline, on the caller's thread. Logos Core's
## `logos_module_dispatch` is one.
##
##     char *dispatch(const char *method, const char *args_json);
##
## This provides the routing half of that: a registry of annotated procs, and a
## generated `case` that decodes arguments, checks arity, calls the proc and
## encodes the result. It does NOT emit any C symbol -- the ABI that wants one
## knows its own name, ownership rules and error vocabulary, and supplies them.
##
## ## Why inline, and not the FFI thread
##
## The obvious implementation parks the caller on a `ThreadSignalPtr` while the
## FFI thread runs the handler, as the generated destructor already does. It
## deadlocks the moment two such libraries call each other.
##
## A calls B, and B calls back into A. Handler 1 occupies A's FFI thread and
## blocks in the outbound call. The host re-enters A's dispatch on its own
## thread, where `onFFIThread` is false, so the re-entrancy guard does not fire
## and the request is queued -- onto a thread that is blocked waiting for it.
## Handlers are never timed out, so it never unwinds.
##
## Run the handler inline and there is no queue and no service thread: A -> B ->
## A is one more stack frame. Re-entrancy stops being a hazard and becomes a
## property. The cost is that handlers are ordinary synchronous procs -- no
## `await` -- which is the right trade when the ABI is synchronous anyway.
import std/[json, macros, tables]

type
  DispatchError* = object
    ## Why a call could not be made. The ABI decides how to render these: one
    ## may want a JSON object, another a status code, another a NULL.
    kind*: DispatchErrorKind
    meth*: string
    wantArity*, gotArity*: int
    argIndex*: int
    wantType*, gotType*: string
    message*: string   ## for deRaised

  DispatchErrorKind* = enum
    deUnknownMethod    ## no such method in the registry
    deArity            ## wrong number of arguments
    deArgType          ## an argument was not the type the proc takes
    deRaised           ## the handler raised

  DispatchResult* = object
    ## Exactly one of these is meaningful, per `ok`.
    ok*: bool
    value*: JsonNode
    err*: DispatchError

  DispatchHandler* = proc(args: JsonNode): DispatchResult {.raises: [].}
    ## `raises: []` but deliberately NOT `gcsafe`. A handler is ordinary module
    ## code and will touch module state; demanding gcsafe would push every
    ## author into globals-behind-accessors for a guarantee inline dispatch
    ## does not need. What it DOES need is that nothing escapes -- an exception
    ## unwinding into a foreign caller's frame is undefined behaviour -- hence
    ## `raises: []`.
    ##
    ## The corollary is that the ABI must serialise calls into a module, or the
    ## module must lock its own state. Logos says so in metadata.json with
    ## `concurrency: "single"`.

func ok*(v: JsonNode): DispatchResult =
  DispatchResult(ok: true, value: v)

func failUnknown*(meth: string): DispatchResult =
  DispatchResult(ok: false, err: DispatchError(kind: deUnknownMethod, meth: meth))

func failArity*(meth: string, want, got: int): DispatchResult =
  DispatchResult(ok: false, err: DispatchError(
    kind: deArity, meth: meth, wantArity: want, gotArity: got))

func failRaised*(meth, message: string): DispatchResult =
  ## A handler that raises is a fault, not a refusal -- but it must not unwind
  ## into a foreign caller's frame, so it is caught at the boundary and
  ## reported like any other dispatch failure.
  DispatchResult(ok: false, err: DispatchError(
    kind: deRaised, meth: meth, message: message))

func failArgType*(meth: string, at: int, want: string, got: JsonNode): DispatchResult =
  let gotName = case got.kind
    of JString: "string"
    of JInt, JFloat: "number"
    of JBool: "boolean"
    of JNull: "null"
    of JArray: "array"
    of JObject: "object"
  DispatchResult(ok: false, err: DispatchError(
    kind: deArgType, meth: meth, argIndex: at, wantType: want, gotType: gotName))

type
  DispatchParam* = object
    ## A parameter as written in Nim. The NIM type name, not a wire spelling:
    ## nim-ffi does not know what an ABI calls a string, and should not.
    name*: string
    nimType*: string

  DispatchMethodMeta* = object
    ## Enough for an ABI to build its own introspection manifest without
    ## re-parsing anything.
    wireName*: string
    procName*: string
    params*: seq[DispatchParam]
    returnType*: string      ## "" when the proc returns nothing
    doc*: string             ## the proc's doc comment, first line

# ------------------------------------------------------------- the registry

type DispatchTable* = Table[string, DispatchHandler]

proc register*(t: var DispatchTable, wireName: string, h: DispatchHandler) =
  t[wireName] = h

proc dispatch*(t: DispatchTable, meth: string, args: JsonNode): DispatchResult =
  ## Routes by name. An unknown method is reported rather than raised, because
  ## on most of these ABIs it is an ordinary answer, not a fault.
  if not t.hasKey(meth):
    return failUnknown(meth)
  return t[meth](args)
