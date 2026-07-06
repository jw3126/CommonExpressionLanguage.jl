using CommonExpressionLanguage
const CEL = CommonExpressionLanguage
using Test
using TimeZones  # activates the IANA-timezone extension used by conformance

@testset "CommonExpressionLanguage.jl" begin
    @testset "parser" begin
        include("test_parser.jl")
    end

    @testset "evaluation" begin
        include("test_eval.jl")
    end

    @testset "checker" begin
        include("test_checker.jl")
    end

    @testset "transpiler" begin
        include("test_transpile.jl")
    end

    include("conformance.jl")

    # cel-spec conformance files fully supported today. Not run (see plan):
    #   - optionals, unknowns, *_ext files: CEL extensions, not implemented
    #   - proto-message tests inside the files below auto-skip until the
    #     ProtocGen.jl adapter lands (reported in the skip counts)
    CONFORMANCE_FILES = ["plumbing", "basic", "comparisons", "integer_math",
        "fp_math", "string", "lists", "logic", "conversions", "macros",
        "macros2", "namespace", "fields", "parse", "timestamps", "dynamic",
        "enums", "wrappers", "proto2", "proto3", "type_deduction"]
    SKIP = Dict{String,String}()  # every non-passing test must be excused here

    @testset "conformance ($backend)" for backend in (:closure, :transpile)
        BACKEND[] = backend
        outcomes, unexpected, stale = conformance_report(CONFORMANCE_FILES, SKIP)
        for o in unexpected
            @error "conformance failure" o.key o.detail
        end
        @test isempty(unexpected)
        @test isempty(stale)
        @test count(o -> o.status == :pass, outcomes) >= 1200
    end
end
