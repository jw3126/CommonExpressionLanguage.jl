using CommonExpressionLanguage
const CEL = CommonExpressionLanguage
using Test

runt(src; vars=Dict{String,Any}(), env=Env()) =
    Base.invokelatest(eval(transpile_function(src; env)), CEL.to_cel_vars(vars))

@testset "transpiled evaluation" begin
    @test runt("1 + 2 * 3") === Int64(7)
    @test runt("false && (1/0 > 0)") === false
    @test runt("x * 2", vars=Dict("x" => 21)) === Int64(42)
    @test runt("[1,2,3].map(x, x * x)") == Any[1, 4, 9]
    @test runt("size(\"héllo\")") === Int64(5)
    @test runt("1/0") isa CelError
    @test runt("has({'a': 1}.b)") === false
end

@testset "varmap: codegen-style direct bindings" begin
    # protovalidate shape: `this` bound to a struct field expression
    struct FakeMsg
        name::String
    end
    fdef = transpile_function("size(this) <= 5 && this.startsWith(\"a\")";
        varmap=Dict{String,Any}("this" => :(msg.name)), varsdict=nothing,
        fname=:validate_name)
    wrapper = eval(:(function (msg::$FakeMsg)
        $(transpile("size(this) <= 5 && this.startsWith(\"a\")";
            varmap=Dict{String,Any}("this" => :(msg.name)), varsdict=nothing))
    end))
    @test Base.invokelatest(wrapper, FakeMsg("abc")) === true
    @test Base.invokelatest(wrapper, FakeMsg("abcdefg")) === false
    @test Base.invokelatest(wrapper, FakeMsg("xyz")) === false

    # unresolvable variables without a vars dict become errors
    err = Base.invokelatest(eval(transpile_function("nope + 1"; varsdict=nothing)))
    @test err isa CelError && err.kind == :no_such_attribute
end

@testset "transpiled output is printable source" begin
    ex = transpile("1 + x"; varsdict=:vars)
    s = string(ex)
    @test occursin("CommonExpressionLanguage.cel_add", s)
    # round-trips through Meta.parse
    ex2 = Meta.parse(s)
    f = eval(:(vars -> $ex2))
    @test Base.invokelatest(f, Dict{String,Any}("x" => Int64(1))) === Int64(2)
end
