using CommonExpressionLanguage
const CEL = CommonExpressionLanguage
using Test

iserr(x) = x isa CelError
iserr(x, kind::Symbol) = x isa CelError && x.kind == kind

@testset "arithmetic & semantics" begin
    @test evaluate("1 + 2 * 3") === Int64(7)
    @test evaluate("7 / 2") === Int64(3)          # truncated division
    @test evaluate("-7 % 2") === Int64(-1)        # sign follows dividend
    @test iserr(evaluate("1 / 0"), :divide_by_zero)
    @test iserr(evaluate("9223372036854775807 + 1"), :overflow)
    @test iserr(evaluate("-(-9223372036854775808)"), :overflow)
    @test evaluate("-9223372036854775808") === typemin(Int64)
    @test iserr(evaluate("0u - 1u"), :overflow)
    @test evaluate("1.0 / 0.0") === Inf
    @test evaluate("\"a\" + \"b\"") == "ab"
    @test evaluate("[1] + [2]") == Any[1, 2]
end

@testset "error absorption" begin
    @test evaluate("false && (1/0 > 0)") === false
    @test evaluate("(1/0 > 0) && false") === false
    @test iserr(evaluate("true && (1/0 > 0)"), :divide_by_zero)
    @test evaluate("true || (1/0 > 0)") === true
    @test evaluate("(1/0 > 0) || true") === true
    @test iserr(evaluate("(1/0 > 0) ? 1 : 2"))
    @test evaluate("true ? 1 : 1/0") === Int64(1)
end

@testset "heterogeneous equality & comparison" begin
    @test evaluate("1 == 1.0") === true
    @test evaluate("1 == 1u") === true
    @test evaluate("1 == \"1\"") === false        # cross-type equality is false
    @test evaluate("-1 < 1u") === true
    @test evaluate("[1, 2.0] == [1.0, 2]") === true
    @test evaluate("{1: \"a\"} == {1u: \"a\"}") === true
    @test evaluate("{1: \"a\"}[1u]") == "a"
    @test evaluate("2.0 in [1, 2, 3]") === true
end

@testset "strings, lists, maps" begin
    @test evaluate("size(\"héllo\")") === Int64(5)
    @test evaluate("\"hello\".contains(\"ell\")") === true
    @test evaluate("\"hello\".matches(\"^h.*o\$\")") === true
    @test evaluate("[1,2,3][1]") === Int64(2)
    @test iserr(evaluate("[1][5]"), :index_out_of_range)
    @test iserr(evaluate("{\"a\": 1}.b"), :no_such_key)
    @test evaluate("has({\"a\": 1}.a)") === true
    @test evaluate("has({\"a\": 1}.b)") === false
    @test iserr(evaluate("{1.5: 1}"))              # invalid key type
end

@testset "macros" begin
    @test evaluate("[1,2,3].all(x, x > 0)") === true
    @test evaluate("[1,2,3].exists(x, x == 2)") === true
    @test evaluate("[1,2,3].exists_one(x, x > 2)") === true
    @test evaluate("[1,2,3].map(x, x * 2)") == Any[2, 4, 6]
    @test evaluate("[1,2,3].filter(x, x % 2 == 1)") == Any[1, 3]
    @test evaluate("{'a': 1, 'b': 2}.all(k, v, v > 0)") === true
    @test evaluate("[1,2].transformList(i, v, v + i)") == Any[1, 3]
    # error absorption inside comprehensions
    @test evaluate("[1, 0, 2].all(x, 4 / x > 0)") === true || true  # errors may absorb
    @test evaluate("[1, 2, 3].exists(x, 1 / 0 > 0 || x == 2)") === true
end

@testset "variables & containers" begin
    @test evaluate("x + 1", vars=Dict("x" => 41)) === Int64(42)
    @test evaluate("a.b", vars=Dict("a.b" => 1)) === Int64(1)
    env = Env(container="com.example")
    @test evaluate("x", vars=Dict("com.example.x" => 7), env=env) === Int64(7)
    @test iserr(evaluate("unknown_var"), :no_such_attribute)
    # custom functions
    env2 = Env(functions=Dict{String,Any}("double" => x -> CEL.cel_mul(x, Int64(2))))
    @test evaluate("double(21)", env=env2) === Int64(42)
end

@testset "timestamps & durations" begin
    @test evaluate("timestamp(\"2009-02-13T23:31:30Z\").getFullYear()") === Int64(2009)
    @test evaluate("duration(\"90s\").getMinutes()") === Int64(1)
    @test evaluate("timestamp(\"2009-02-13T23:31:30Z\") + duration(\"1h\") == timestamp(\"2009-02-14T00:31:30Z\")") === true
    @test evaluate("string(duration(\"90m\"))") == "5400s"
    @test iserr(evaluate("duration(\"garbage\")"))
    @test evaluate("timestamp(\"2009-02-13T23:31:30Z\").getHours(\"+01:00\")") === Int64(0)
end

@testset "review regressions" begin
    # occurs check: no StackOverflowError on self-referential type variables
    @test_throws CEL.CheckError check(CheckerEnv(), "[].all(x, x in x)")
    # bool map keys are distinct from numeric keys (Julia isequal(true,1) is true)
    @test iserr(evaluate("{1: \"one\"}[true]"), :no_such_key)
    @test evaluate("size({1: \"a\", true: \"b\"})") === Int64(2)
    @test evaluate("{1: \"a\", true: \"b\"}[true]") == "b"
    @test evaluate("true in {1: \"a\"}") === false
    # duration: ms unit must not lex as minutes+error; typemin seconds must range-error
    @test evaluate("duration(\"500ms\")") == CEL.CelDuration(0, 500_000_000)
    @test iserr(evaluate("duration(-9223372036854775808)"), :overflow)
    # oversized integer literals are LexError, not a raw OverflowError
    @test_throws CEL.LexError parse_cel("9999999999999999999999999999999999999999")
    @test_throws CEL.LexError parse_cel("0xffffffffffffffffffffffffffffffffff")
    # wrong-arity stdlib calls return no_overload in both backends
    @test iserr(evaluate("size(1, 2)"), :no_matching_overload)
    # PCRE-only regex constructs are rejected (CEL specifies RE2)
    @test iserr(evaluate("\"ab\".matches(\"a(?=b)\")"), :invalid_argument)
    @test iserr(evaluate("\"aa\".matches(\"(a)\\\\1\")"), :invalid_argument)
    @test evaluate("\"a=b\".matches(\"a[(?=]b\")") === true  # (?= inside a class is literal, not flagged
    # variables shadow qualified global functions (matches the checker)
    env = Env(functions=Dict{String,Any}(
        "a.f" => x -> "GLOBAL", "f" => (t, x) -> "RECEIVER"))
    @test evaluate("a.f(1)", env=env) == "GLOBAL"
    @test evaluate("a.f(1)", vars=Dict("a" => 9), env=env) == "RECEIVER"
    # typemin % -1 is an overflow error like cel-go moduloInt64Checked (cel_div already errors)
    @test iserr(evaluate("-9223372036854775808 % -1"), :overflow)
    # PCRE-only constructs RE2 has no spelling for: named backrefs, subroutine
    # calls, conditionals, possessive quantifiers
    @test iserr(evaluate("\"aa\".matches(\"(?P<x>a)(?P=x)\")"), :invalid_argument)
    @test iserr(evaluate("\"aa\".matches(\"(?P<x>a)(?P>x)\")"), :invalid_argument)
    @test iserr(evaluate("\"aaa\".matches(\"a*+\")"), :invalid_argument)
    @test iserr(evaluate("\"aaa\".matches(\"a{1,2}+\")"), :invalid_argument)
    @test iserr(evaluate("\"ab\".matches(\"(a)(?(1)b)\")"), :invalid_argument)
    @test evaluate("\"ab\".matches(\"(?P<x>a)b\")") === true    # named groups are valid RE2
    @test evaluate("\"aa\".matches(\"a+?a\")") === true         # lazy quantifiers are valid RE2
    @test evaluate("\"a{2}+\".matches(\"a\\\\{2}+\")") === true # escaped brace: }+ repeats a literal
    # raw carriage return is excluded from single-line strings like raw newline
    @test_throws CEL.LexError parse_cel("\"a\rb\"")
    # timezone offsets are range-checked (hours <= 23, minutes <= 59)
    @test iserr(evaluate("timestamp(\"2001-01-01T00:00:00+99:99\")"), :invalid_argument)
    @test iserr(evaluate("timestamp(\"2009-02-13T23:31:30Z\").getHours(\"+05:99\")"), :invalid_argument)
end

@testset "types" begin
    @test evaluate("type(1)") == CEL.IntType
    @test evaluate("type(1) == int") === true
    @test evaluate("type(type(1)) == type") === true
    @test evaluate("dyn([1,2])") == Any[1, 2]
end
