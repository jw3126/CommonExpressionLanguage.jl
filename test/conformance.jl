# cel-spec conformance harness over the vendored testdata (see
# test/testdata/README.md). Loads SimpleTestFile textprotos, runs each test
# through parse -> compile -> eval, and matches the expected result.
#
# Every non-passing test must be accounted for in SKIP (with a reason);
# unexpected failures — and stale SKIP entries that now pass — fail the suite.

using CommonExpressionLanguage
const CEL = CommonExpressionLanguage
using OrderedCollections: OrderedDict
using Test

include("textproto.jl")
using .TextProto: parse_file, getone, getall, asstring

# ------------------------------------------------------------------
# cel.expr.Value (textproto dict) -> CEL runtime value
# ------------------------------------------------------------------

struct Unsupported
    why::String
end

function from_value(d::AbstractDict)
    haskey(d, "int64_value") && return parse(Int64, getone(d, "int64_value"))
    haskey(d, "uint64_value") && return parse(UInt64, getone(d, "uint64_value"))
    haskey(d, "double_value") && return parse_tp_double(getone(d, "double_value"))
    haskey(d, "string_value") && return asstring(getone(d, "string_value"))
    haskey(d, "bytes_value") && return CEL.CelBytes(copy(getone(d, "bytes_value"))::Vector{UInt8})
    haskey(d, "bool_value") && return getone(d, "bool_value")::Bool
    haskey(d, "null_value") && return nothing
    haskey(d, "type_value") && return CEL.CelType(asstring(getone(d, "type_value")))
    if haskey(d, "list_value")
        lv = getone(d, "list_value")
        vals = Any[]
        for v in getall(lv, "values")
            cv = from_value(v)
            cv isa Unsupported && return cv
            push!(vals, cv)
        end
        return vals
    end
    if haskey(d, "map_value")
        mv = getone(d, "map_value")
        m = OrderedDict{Any,Any}()
        for e in getall(mv, "entries")
            k = from_value(getone(e, "key"))
            v = from_value(getone(e, "value"))
            k isa Unsupported && return k
            v isa Unsupported && return v
            m[k] = v
        end
        return m
    end
    haskey(d, "object_value") && return Unsupported("object_value (proto message)")
    haskey(d, "enum_value") && return Unsupported("enum_value")
    isempty(d) && return Unsupported("empty Value")
    return Unsupported("value kind $(collect(keys(d)))")
end

function parse_tp_double(s)
    str = lowercase(String(s isa Symbol ? String(s) : s))
    str in ("inf", "infinity") && return Inf
    str in ("-inf", "-infinity") && return -Inf
    str == "nan" && return NaN
    v = tryparse(Float64, str)
    v !== nothing && return v
    # subnormal underflow like 1e-324: round via BigFloat as protobuf does
    return Float64(parse(BigFloat, str))
end

# ------------------------------------------------------------------
# cel.expr.Type (textproto dict) -> static SType
# ------------------------------------------------------------------

const PRIMITIVE_T = Dict(
    :BOOL => CEL.BOOL_T, :INT64 => CEL.INT_T, :UINT64 => CEL.UINT_T,
    :DOUBLE => CEL.DOUBLE_T, :STRING => CEL.STRING_T, :BYTES => CEL.BYTES_T,
)

function from_type(d::AbstractDict)
    haskey(d, "primitive") && return get(PRIMITIVE_T, getone(d, "primitive"), Unsupported("primitive"))
    haskey(d, "dyn") && return CEL.DYN_T
    haskey(d, "null") && return CEL.NULL_T
    if haskey(d, "well_known")
        wk = getone(d, "well_known")
        wk === :TIMESTAMP && return CEL.TIMESTAMP_T
        wk === :DURATION && return CEL.DURATION_T
        return Unsupported("well_known $wk")
    end
    if haskey(d, "list_type")
        el = from_type(getone(getone(d, "list_type"), "elem_type", OrderedDict{String,Vector{Any}}()))
        el isa Unsupported && return el
        return CEL.list_of(el)
    end
    if haskey(d, "map_type")
        mt = getone(d, "map_type")
        k = from_type(getone(mt, "key_type", OrderedDict{String,Vector{Any}}()))
        v = from_type(getone(mt, "value_type", OrderedDict{String,Vector{Any}}()))
        (k isa Unsupported || v isa Unsupported) && return Unsupported("map type")
        return CEL.map_of(k, v)
    end
    haskey(d, "message_type") && return CEL.msg_t(asstring(getone(d, "message_type")))
    haskey(d, "type_param") && return CEL.param_t(asstring(getone(d, "type_param")))
    if haskey(d, "type")
        inner = getone(d, "type")
        inner isa AbstractDict && !isempty(inner) || return CEL.type_of(CEL.DYN_T)
        it = from_type(inner)
        it isa Unsupported && return it
        return CEL.type_of(it)
    end
    haskey(d, "wrapper") && return Unsupported("wrapper type")
    haskey(d, "abstract_type") && return Unsupported("abstract type")
    haskey(d, "function") && return Unsupported("function type")
    return Unsupported("type kind $(collect(keys(d)))")
end

has_message_type(t::CEL.SType) =
    t.kind == CEL.TypeKind.Message || any(has_message_type, t.params)

"Does the AST contain message construction (requires the proto adapter)?"
has_struct_expr(e::CEL.CelExpr) = false
has_struct_expr(e::CEL.StructExpr) = true
has_struct_expr(e::CEL.SelectExpr) = has_struct_expr(e.operand)
has_struct_expr(e::CEL.CallExpr) =
    (e.target !== nothing && has_struct_expr(e.target)) || any(has_struct_expr, e.args)
has_struct_expr(e::CEL.ListExpr) = any(has_struct_expr, e.elements)
has_struct_expr(e::CEL.MapExpr) =
    any(en -> has_struct_expr(en.key) || has_struct_expr(en.value), e.entries)
has_struct_expr(e::CEL.ComprehensionExpr) =
    has_struct_expr(e.iter_range) || has_struct_expr(e.accu_init) ||
    has_struct_expr(e.loop_condition) || has_struct_expr(e.loop_step) ||
    has_struct_expr(e.result)

"Structural type equality ignoring type-parameter names."
function stype_matches(e::CEL.SType, a::CEL.SType)
    e.kind == CEL.TypeKind.TypeParam && return a.kind == CEL.TypeKind.TypeParam
    e.kind == a.kind || return false
    e.name == a.name || return false
    length(e.params) == length(a.params) || return false
    return all(stype_matches(x, y) for (x, y) in zip(e.params, a.params))
end

# ------------------------------------------------------------------
# Conformance equality: exact type + CEL value equality; NaN == NaN
# ------------------------------------------------------------------

conf_equal(e::Float64, a) = a isa Float64 && ((isnan(e) && isnan(a)) || e == a)
conf_equal(e::Int64, a) = a isa Int64 && e == a
conf_equal(e::UInt64, a) = a isa UInt64 && e == a
conf_equal(e::Bool, a) = a isa Bool && e == a
conf_equal(e::String, a) = a isa String && e == a
conf_equal(e::CEL.CelBytes, a) = a isa CEL.CelBytes && e.data == a.data
conf_equal(e::Nothing, a) = a === nothing
conf_equal(e::CEL.CelType, a) = a isa CEL.CelType && e.name == a.name
conf_equal(e::CEL.CelTimestamp, a) = a isa CEL.CelTimestamp && e == a
conf_equal(e::CEL.CelDuration, a) = a isa CEL.CelDuration && e == a
function conf_equal(e::AbstractVector, a)
    a isa AbstractVector || return false
    length(e) == length(a) || return false
    return all(conf_equal(e[i], a[i]) for i in eachindex(e))
end
function conf_equal(e::AbstractDict, a)
    a isa AbstractDict || return false
    length(e) == length(a) || return false
    for (k, v) in e
        matched = false
        for (ak, av) in a
            if conf_equal(k, ak)
                matched = conf_equal(v, av)
                break
            end
        end
        matched || return false
    end
    return true
end
conf_equal(e, a) = false

# ------------------------------------------------------------------
# Runner
# ------------------------------------------------------------------

struct TestOutcome
    key::String       # "file/section/test"
    status::Symbol    # :pass, :fail, :skip
    detail::String
end

# Which evaluation backend the harness exercises: :closure or :transpile
const BACKEND = Ref(:closure)

function run_test(fdict, sname, t)
    expr = asstring(getone(t, "expr"))
    container = something(asstring(getone(t, "container")), "")
    disable_check = something(getone(t, "disable_check"), false) === true

    bindings = Dict{String,Any}()
    for b in getall(t, "bindings")
        key = asstring(getone(b, "key"))
        ev = getone(b, "value")
        v = haskey(ev, "value") ? from_value(getone(ev, "value")) : Unsupported("non-value binding")
        v isa Unsupported && return (:skip, "binding: $(v.why)")
        bindings[key] = v
    end

    variables = Dict{String,CEL.SType}()
    for d in getall(t, "type_env")
        dname = asstring(getone(d, "name"))
        if haskey(d, "ident")
            st = from_type(getone(getone(d, "ident"), "type"))
            st isa Unsupported && return (:skip, "type_env: $(st.why)")
            has_message_type(st) && return (:skip, "proto-blocked: message-typed variable")
            variables[dname] = st
        else
            return (:skip, "type_env function declaration")
        end
    end
    check_only = something(getone(t, "check_only"), false) === true

    expect_error = haskey(t, "eval_error") || haskey(t, "any_eval_errors")
    expected = nothing
    deduced = nothing
    if haskey(t, "value")
        expected = from_value(getone(t, "value"))
        expected isa Unsupported && return (:skip, "expected: $(expected.why)")
    elseif haskey(t, "typed_result")
        tr = getone(t, "typed_result")
        if haskey(tr, "deduced_type")
            deduced = from_type(getone(tr, "deduced_type"))
            deduced isa Unsupported && return (:skip, "deduced_type: $(deduced.why)")
        end
        haskey(tr, "result") || deduced !== nothing || return (:skip, "empty typed_result")
        if haskey(tr, "result")
            expected = from_value(getone(tr, "result"))
            expected isa Unsupported && return (:skip, "expected: $(expected.why)")
        else
            expected = true
        end
    elseif haskey(t, "unknown") || haskey(t, "any_unknowns")
        return (:skip, "unknown-result matcher")
    elseif !expect_error
        expected = true  # default matcher per simple.proto
    end

    # parse. An expected *evaluation* error is never satisfied by a parse
    # failure — a parser regression must not turn eval_error tests green.
    parsed = try
        parse_cel(expr)
    catch ex
        ex isa Union{CEL.ParseError,CEL.LexError} || rethrow()
        return (:fail, "parse error: $(sprint(showerror, ex))")
    end

    # Upfront proto-blocked classification (instead of post-hoc matching on
    # failure messages): message construction always needs the proto adapter,
    # and the conformance suite's enum constants are fixed identifiers.
    if has_struct_expr(parsed.expr) ||
       occursin(r"\b(TestAllTypes|GlobalEnum|NestedEnum|NullValue)\b", expr)
        return (:skip, "proto-blocked: requires proto adapter")
    end

    # check. A CheckError satisfies eval_error matchers: conformance drivers
    # run checked mode by default, and e.g. type-mismatch errors are raised
    # at check time rather than eval time.
    if !disable_check
        cenv = CheckerEnv(; container, variables)
        checked = try
            check(cenv, parsed)
        catch ex
            ex isa CEL.CheckError || rethrow()
            expect_error && return (:pass, "")
            return (:fail, "check error: $(ex.msg)")
        end
        if deduced !== nothing
            roott = checked.types[parsed.expr.id]
            stype_matches(deduced, roott) ||
                return (:fail, "deduced type $(roott) != expected $(deduced)")
        end
    end
    check_only && return (:pass, "")

    result = if BACKEND[] === :transpile
        fdef = transpile_function(expr; env=Env(; container))
        f = Base.eval(Main, fdef)
        Base.invokelatest(f, CEL.to_cel_vars(bindings))
    else
        evaluate(expr; vars=bindings, env=Env(; container))
    end

    if expect_error
        result isa CelError && return (:pass, "")
        return (:fail, "expected error, got $(repr(result))")
    else
        result isa CelError && return (:fail, "unexpected error: $(result.kind): $(result.msg)")
        conf_equal(expected, result) && return (:pass, "")
        return (:fail, "expected $(repr(expected)), got $(repr(result))")
    end
end

function run_conformance_file(path::AbstractString)
    fdict = parse_file(path)
    fname = something(asstring(getone(fdict, "name")), basename(path))
    outcomes = TestOutcome[]
    for s in getall(fdict, "section")
        sname = asstring(getone(s, "name"))
        for t in getall(s, "test")
            tname = asstring(getone(t, "name"))
            key = "$fname/$sname/$tname"
            status, detail = try
                run_test(fdict, sname, t)
            catch ex
                (:fail, "exception: $(sprint(showerror, ex))")
            end
            push!(outcomes, TestOutcome(key, status, detail))
        end
    end
    return outcomes
end

"""
Run conformance for the given files. Failing tests must appear in `skip`
(key => reason); skipped-but-passing entries are reported as stale.
Returns `(outcomes, unexpected_failures, stale_skips, per_file_counts)`;
`per_file_counts` maps file => (pass, skip) so callers can pin exact numbers
and detect silent pass→skip drift.
"""
function conformance_report(files::Vector{String}, skip::AbstractDict{String,String})
    all_outcomes = TestOutcome[]
    counts = Dict{String,Tuple{Int,Int}}()
    for f in files
        path = joinpath(@__DIR__, "testdata", f * ".textproto")
        outcomes = run_conformance_file(path)
        append!(all_outcomes, outcomes)
        npass = count(o -> o.status == :pass, outcomes)
        nskip = count(o -> o.status == :skip, outcomes)
        nfail = count(o -> o.status == :fail, outcomes)
        nexcused = count(o -> o.status == :fail && haskey(skip, o.key), outcomes)
        counts[f] = (npass, nskip + nexcused)
        println(rpad(f, 16), " pass=", npass, " skip=", nskip + nexcused,
            nfail - nexcused > 0 ? " FAIL=$(nfail - nexcused)" : "")
    end
    unexpected = [o for o in all_outcomes if o.status == :fail && !haskey(skip, o.key)]
    stale = [k for k in keys(skip) if any(o -> o.key == k && o.status == :pass, all_outcomes)]
    return all_outcomes, unexpected, stale, counts
end
