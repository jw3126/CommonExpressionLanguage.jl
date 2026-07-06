using CommonExpressionLanguage
const CEL = CommonExpressionLanguage
using Test

# Convenience: parse and return root node
root(s) = parse_cel(s).expr

@testset "lexer" begin
    toks = CEL.tokenize("1 + 2u * 3.5")
    @test [t.kind for t in toks] == [CEL.TokenKind.INT, CEL.TokenKind.PLUS, CEL.TokenKind.UINT, CEL.TokenKind.STAR, CEL.TokenKind.FLOAT, CEL.TokenKind.EOF]
    @test CEL.tokenize("0x2Au")[1].value === UInt64(42)
    @test CEL.tokenize("1e3")[1].value === 1000.0
    @test CEL.tokenize(".5")[1].value === 0.5
    @test CEL.tokenize("\"a\\nb\"")[1].value == "a\nb"
    @test CEL.tokenize("'\\u00e9'")[1].value == "é"
    @test CEL.tokenize("'\\U0001F600'")[1].value == "😀"
    @test CEL.tokenize("'\\101'")[1].value == "A"
    @test CEL.tokenize("r'\\n'")[1].value == "\\n"
    @test CEL.tokenize("b'\\xff'")[1].value == CEL.CelBytes([0xff])
    @test CEL.tokenize("b'abc'")[1].value == CEL.CelBytes("abc")
    @test CEL.tokenize("'''x''y'''")[1].value == "x''y"
    @test CEL.tokenize("\"\"\"line1\nline2\"\"\"")[1].value == "line1\nline2"
    @test CEL.tokenize("// comment\nfoo")[1].kind == CEL.TokenKind.IDENT
    @test_throws CEL.LexError CEL.tokenize("'unterminated")
    @test_throws CEL.LexError CEL.tokenize("b'\\u0041'")
    @test_throws CEL.LexError CEL.tokenize("@")
end

@testset "literals" begin
    @test root("42") == CEL.ConstExpr(1, Int64(42))
    @test root("-7").value === Int64(-7)
    @test root("-9223372036854775808").value === typemin(Int64)
    @test_throws CEL.ParseError parse_cel("9223372036854775808")
    @test root("18446744073709551615u").value === typemax(UInt64)
    @test root("1.5e2").value === 150.0
    @test root("-2.5").value === -2.5
    @test root("true").value === true
    @test root("null").value === nothing
    @test root("'hi'").value == "hi"
end

@testset "operators and precedence" begin
    e = root("1 + 2 * 3")
    @test e isa CEL.CallExpr && e.fname == "_+_"
    @test e.args[2].fname == "_*_"

    e = root("a || b && c")
    @test e.fname == "_||_" && e.args[2].fname == "_&&_"

    e = root("a < b == c")   # left-assoc relations
    @test e.fname == "_==_" && e.args[1].fname == "_<_"

    e = root("x in [1, 2]")
    @test e.fname == "@in" && e.args[2] isa CEL.ListExpr

    e = root("c ? x : y ? z : w")   # ternary right-assoc
    @test e.fname == "_?_:_" && e.args[3].fname == "_?_:_"

    e = root("!!true")
    @test e isa CEL.ConstExpr   # double negation folded

    e = root("-x")
    @test e.fname == "-_"

    e = root("a[0]")
    @test e.fname == "_[_]"
end

@testset "member/select/calls" begin
    e = root("a.b.c")
    @test e isa CEL.SelectExpr && e.field == "c" && e.operand.field == "b"

    e = root("size('abc')")
    @test e isa CEL.CallExpr && e.fname == "size" && e.target === nothing

    e = root("'abc'.contains('b')")
    @test e isa CEL.CallExpr && e.fname == "contains" && e.target isa CEL.ConstExpr

    e = root(".a.b")
    @test e isa CEL.SelectExpr && e.operand.name == ".a"

    e = root("{'k': 1, 2: true}")
    @test e isa CEL.MapExpr && length(e.entries) == 2

    e = root("[1, 2, 3,]")   # trailing comma
    @test e isa CEL.ListExpr && length(e.elements) == 3

    e = root("pkg.Msg{f: 1, g: 'x'}")
    @test e isa CEL.StructExpr && e.message_name == "pkg.Msg" && length(e.entries) == 2

    e = root(".pkg.Msg{}")
    @test e isa CEL.StructExpr && e.message_name == ".pkg.Msg"
end

@testset "macros" begin
    e = root("has(a.b)")
    @test e isa CEL.SelectExpr && e.test_only
    @test_throws CEL.ParseError parse_cel("has(a)")
    @test_throws CEL.ParseError parse_cel("has(a[0])")

    e = root("[1,2].all(x, x > 0)")
    @test e isa CEL.ComprehensionExpr
    @test e.iter_var == "x" && e.iter_var2 == "" && e.accu_var == "__result__"
    @test e.loop_step.fname == "_&&_"

    e = root("[1,2].exists(x, x > 0)")
    @test e isa CEL.ComprehensionExpr && e.loop_step.fname == "_||_"

    e = root("[1,2].exists_one(x, x > 0)")
    @test e isa CEL.ComprehensionExpr && e.result.fname == "_==_"

    e = root("[1,2].map(x, x * 2)")
    @test e isa CEL.ComprehensionExpr && e.loop_step.fname == "_+_"

    e = root("[1,2].map(x, x > 0, x * 2)")
    @test e isa CEL.ComprehensionExpr && e.loop_step.fname == "_?_:_"

    e = root("[1,2].filter(x, x > 0)")
    @test e isa CEL.ComprehensionExpr

    e = root("{'a':1}.all(k, v, v > 0)")
    @test e isa CEL.ComprehensionExpr && e.iter_var == "k" && e.iter_var2 == "v"

    @test_throws CEL.ParseError parse_cel("[1].all(2, x > 0)")
    @test_throws CEL.ParseError parse_cel("[1].all(__result__, true)")

    # non-macro arity falls through to a normal call
    e = root("x.map(a)")
    @test e isa CEL.CallExpr && e.fname == "map"
end

@testset "errors" begin
    @test_throws CEL.ParseError parse_cel("")
    @test_throws CEL.ParseError parse_cel("1 +")
    @test_throws CEL.ParseError parse_cel("(1")
    @test_throws CEL.ParseError parse_cel("if")
    @test parse_cel("a.if").expr isa CEL.SelectExpr  # reserved words are valid selectors
    @test_throws CEL.ParseError parse_cel("a.")
    @test_throws CEL.ParseError parse_cel("1 1")
    # deep nesting hits the recursion limit rather than a stack overflow
    @test_throws CEL.ParseError parse_cel("("^300 * "1" * ")"^300)
end
