## logos-nim-sdk — both halves.
##
##   consumer: drive Logos modules from a Nim application. `logos_api.nim`,
##             which dlopens liblogos_core. Import it directly.
##
##   provider: BE a Logos module. The modules below implement the pieces of the
##             `logos_module_*` ABI a Nim module needs -- the {"_bytes":...}
##             convention, the answer and refusal shapes, and calling another
##             module through lp_invoke.
##
## The provider half is deliberately not a framework. Until logos-lidl-gen
## grows a Nim backend, a module still writes its own seven exports and its own
## dispatch table; what it should not have to write again is base64url, the
## rejection fold, or the Qt metatype spellings. Those are here.
import ./sdk/bytes
import ./sdk/wire
import ./sdk/lp_client
import ./sdk/module

export bytes, wire, lp_client, module
