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
    #     ProtocGen.jl adapter lands (classified upfront in run_test)
    #
    # Exact (pass, skip) counts are pinned so that pass -> skip drift is as
    # loud as a failure. When a feature lands (e.g. the proto adapter),
    # update the table alongside it.
    EXPECTED_COUNTS = Dict(
        "plumbing" => (5, 0),
        "basic" => (43, 0),
        "comparisons" => (334, 72),
        "integer_math" => (64, 0),
        "fp_math" => (30, 0),
        "string" => (51, 0),
        "lists" => (39, 0),
        "logic" => (30, 0),
        "conversions" => (109, 0),
        "macros" => (44, 0),
        "macros2" => (46, 0),
        "namespace" => (14, 0),
        "fields" => (60, 0),
        "parse" => (193, 26),
        "timestamps" => (77, 1),
        "dynamic" => (0, 226),
        "enums" => (0, 85),
        "wrappers" => (0, 36),
        "proto2" => (0, 118),
        "proto3" => (0, 85),
        "type_deduction" => (15, 32),
    )
    CONFORMANCE_FILES = sort!(collect(keys(EXPECTED_COUNTS)))
    SKIP = Dict{String,String}()  # every non-passing test must be excused here

    @testset "conformance ($backend)" for backend in (:closure, :transpile)
        BACKEND[] = backend
        outcomes, unexpected, stale, counts = conformance_report(CONFORMANCE_FILES, SKIP)
        for o in unexpected
            @error "conformance failure" o.key o.detail
        end
        @test isempty(unexpected)
        @test isempty(stale)
        for f in CONFORMANCE_FILES
            @test (f, counts[f]) == (f, EXPECTED_COUNTS[f])
        end
    end
end
