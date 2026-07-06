using CommonExpressionLanguage
const CEL = CommonExpressionLanguage
using Test

@testset "checker basics" begin
    env = CheckerEnv(variables=Dict("x" => CEL.INT_T, "s" => CEL.STRING_T))
    c = check(env, "x + 1 > 2")
    @test c.types[c.parsed.expr.id] == CEL.BOOL_T

    c = check(env, "[x, 2, 3]")
    @test c.types[c.parsed.expr.id] == CEL.list_of(CEL.INT_T)

    c = check(env, "{s: x}")
    @test c.types[c.parsed.expr.id] == CEL.map_of(CEL.STRING_T, CEL.INT_T)

    # overload ids resolved for unambiguous calls
    c = check(env, "x + 1")
    @test c.overloads[c.parsed.expr.id] == "add_int64"
end

@testset "checker rejects" begin
    env = CheckerEnv(variables=Dict("x" => CEL.INT_T))
    @test_throws CEL.CheckError check(env, "x + \"a\"")       # no overload
    @test_throws CEL.CheckError check(env, "undeclared + 1")  # unknown var
    @test_throws CEL.CheckError check(env, "size(1)")         # no overload
    @test_throws CEL.CheckError check(env, "1 ? 2 : 3")       # cond not bool
    @test_throws CEL.CheckError check(env, "1 == \"a\"")      # cross-type eq is a check error
end

@testset "checker generics & comprehensions" begin
    env = CheckerEnv()
    c = check(env, "[[], [1]]")   # flexible type parameter assignment
    @test c.types[c.parsed.expr.id] == CEL.list_of(CEL.list_of(CEL.INT_T))

    c = check(env, "[1,2,3].map(x, x * 2)")
    @test c.types[c.parsed.expr.id] == CEL.list_of(CEL.INT_T)

    c = check(env, "[1,2,3].exists(x, x > 2)")
    @test c.types[c.parsed.expr.id] == CEL.BOOL_T

    c = check(env, "type(1)")
    @test c.types[c.parsed.expr.id] == CEL.type_of(CEL.INT_T)
end

@testset "checker containers" begin
    env = CheckerEnv(container="com.example", variables=Dict("com.example.x" => CEL.INT_T))
    c = check(env, "x + 1")
    @test c.types[c.parsed.expr.id] == CEL.INT_T
    @test any(v -> v == "com.example.x", values(c.refs))
end
