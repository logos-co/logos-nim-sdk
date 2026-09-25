## The rejection fold is the subtle one: too loose and ordinary data reads as
## an error, too strict and real refusals read as data.
import std/[unittest, json]
import ../sdk/wire

suite "error shapes":
  test "invalid_args wording matches the other scaffolds":
    let r = invalidArgs("m", 2, 1)
    check r["code"].getStr() == "invalid_args"
    check r["message"].getStr() == "expected 2 arguments, got 1"
    check r["origin"].getStr() == "m"

  test "wrong-type wording names the position and both types":
    check wrongType("m", "integer", 0, %"x")["message"].getStr() ==
      "expected integer at arg0, got string"
    check wrongType("m", "string", 2, %*[1])["message"].getStr() ==
      "expected string at arg2, got array"

suite "the rejection fold":
  test "a genuine refusal is recognised":
    check asRejection(%*{"code": "dispatch_failed", "message": "boom",
                         "origin": "m"}) == "boom"
    check asRejection(%*{"code": "invalid_args", "message": "m", "origin": "o"}) == "m"

  test "ordinary data is not":
    # A method may legitimately return three strings. This is the case the
    # narrowness exists for.
    check asRejection(%*{"code": "200", "message": "hello", "origin": "x"}) == ""
    check asRejection(%*{"a": "1", "b": "2", "c": "3"}) == ""
    check asRejection(%*{"code": "dispatch_failed", "message": "m"}) == ""
    check asRejection(%*{"code": "dispatch_failed", "message": "m",
                         "origin": "o", "extra": 1}) == ""
    check asRejection(%*{"code": 1, "message": "m", "origin": "o"}) == ""
    check asRejection(%"a string") == ""
    check asRejection(newJNull()) == ""

suite "manifest type spellings":
  test "the mapping the generator uses":
    check metatypeName("tstr") == "QString"
    check metatypeName("bstr") == "QByteArray"   # NOT QVariant
    check metatypeName("int") == "int"
    check metatypeName("uint") == "int"
    check metatypeName("float64") == "double"
    check metatypeName("bool") == "bool"
    check metatypeName("result") == "LogosResult"
    check metatypeName("any") == "QVariant"
    check metatypeName("SomeRecord") == "QVariant"
