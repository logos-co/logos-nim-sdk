## The shapes a Logos module answers in.
##
## Two of them, and the difference matters:
##
##   * A method's result is a BARE JSON value -- `"op-1"` with its quotes,
##     `true`, `{"_bytes":...}`. Not wrapped in a success envelope.
##   * An argument error is also a *successful* dispatch, carrying an object
##     with exactly three string keys. The consumer folds it back into its
##     error channel. The narrowness is deliberate: a method may legitimately
##     return a three-string map, and it must not be mistaken for a refusal.
##
## Unknown methods are neither -- they are a NULL return, which is why
## `unknown_method` is reserved in the code set below but never emitted here.
import std/json

const
  RejectionCodes* = ["dispatch_failed", "invalid_args", "unknown_method"]
    ## Closed set. A fourth code would be silently ignored by every consumer.

func rejection*(code, message, origin: string): JsonNode =
  return %*{"code": code, "message": message, "origin": origin}

func invalidArgs*(origin: string, want, got: int): JsonNode =
  ## Wording is shared verbatim with the Rust and C++ scaffolds; a consumer's
  ## tests match on it.
  return rejection("invalid_args",
                   "expected " & $want & " arguments, got " & $got, origin)

func dispatchFailed*(origin, message: string): JsonNode =
  return rejection("dispatch_failed", message, origin)

func jsonKindName*(n: JsonNode): string =
  ## The spelling used in "expected X at argN, got Y".
  case n.kind
  of JString: "string"
  of JInt, JFloat: "number"
  of JBool: "boolean"
  of JNull: "null"
  of JArray: "array"
  of JObject: "object"

func wrongType*(origin, want: string, at: int, got: JsonNode): JsonNode =
  return dispatchFailed(origin,
    "expected " & want & " at arg" & $at & ", got " & jsonKindName(got))

func asRejection*(n: JsonNode): string =
  ## The fold a CONSUMER applies to a successful result. Returns the message if
  ## this is a refusal, or "" if it is ordinary data.
  ##
  ## Every clause is load-bearing: exactly three keys, all three present, all
  ## string-valued, and a code from the closed set. Loosen any of them and a
  ## method returning a three-string map starts reading as an error.
  if n == nil or n.kind != JObject or n.len != 3: return ""
  if not (n.hasKey("code") and n.hasKey("message") and n.hasKey("origin")):
    return ""
  if n["code"].kind != JString or n["message"].kind != JString or
     n["origin"].kind != JString: return ""
  if n["code"].getStr() notin RejectionCodes: return ""
  return n["message"].getStr()

# ------------------------------------------------------------ introspection

func qtTypeName*(lidlType: string): string =
  ## `logos_module_get_methods` reports Qt metatype spellings, because the
  ## manifest feeds a Qt-based registry. This is the mapping the Rust generator
  ## uses; a module that spells them differently is invisible to the host's
  ## introspection even though its dispatch works.
  case lidlType
  of "tstr": "QString"
  of "bstr": "QByteArray"
  of "int", "uint": "int"
  of "float64": "double"
  of "bool": "bool"
  of "result": "LogosResult"
  else: "QVariant"      # composites, `any`, and named record types
