# Static type checker (cel-spec "Type Checking", checked.proto semantics).
#
# Unification-based overload resolution over the parsed AST. Produces a
# `CheckedExpr` carrying node-id => type and node-id => overload-id maps,
# which the backends can use to skip dynamic dispatch.

# ------------------------------------------------------------------
# Static types
# ------------------------------------------------------------------

@enumx TypeKind begin
    Int; UInt; Double; Bool; String; Bytes; Null; Dyn; Error
    Timestamp; Duration; List; Map; Type; Message; TypeParam
end

"""
Static CEL type. `params` hold list/map/type parameters; `name` the message
or type-parameter name.
"""
struct SType
    kind::TypeKind.T
    params::Vector{SType}
    name::String
end
SType(kind::TypeKind.T) = SType(kind, SType[], "")
Base.:(==)(a::SType, b::SType) = a.kind == b.kind && a.params == b.params && a.name == b.name
Base.hash(a::SType, h::UInt) = hash((a.kind, a.params, a.name), h)

const INT_T = SType(TypeKind.Int)
const UINT_T = SType(TypeKind.UInt)
const DOUBLE_T = SType(TypeKind.Double)
const BOOL_T = SType(TypeKind.Bool)
const STRING_T = SType(TypeKind.String)
const BYTES_T = SType(TypeKind.Bytes)
const NULL_T = SType(TypeKind.Null)
const DYN_T = SType(TypeKind.Dyn)
const TIMESTAMP_T = SType(TypeKind.Timestamp)
const DURATION_T = SType(TypeKind.Duration)
list_of(t::SType) = SType(TypeKind.List, [t], "")
map_of(k::SType, v::SType) = SType(TypeKind.Map, [k, v], "")
type_of(t::SType) = SType(TypeKind.Type, [t], "")
msg_t(name::String) = SType(TypeKind.Message, SType[], name)
param_t(name::String) = SType(TypeKind.TypeParam, SType[], name)

const TYPE_KIND_NAMES = Dict(
    TypeKind.Int => "int", TypeKind.UInt => "uint", TypeKind.Double => "double",
    TypeKind.Bool => "bool", TypeKind.String => "string", TypeKind.Bytes => "bytes",
    TypeKind.Null => "null_type", TypeKind.Dyn => "dyn", TypeKind.Error => "error",
    TypeKind.Timestamp => "google.protobuf.Timestamp",
    TypeKind.Duration => "google.protobuf.Duration",
    TypeKind.List => "list", TypeKind.Map => "map", TypeKind.Type => "type",
    TypeKind.TypeParam => "type_param",
)

function type_name(t::SType)
    t.kind == TypeKind.Message && return t.name
    return TYPE_KIND_NAMES[t.kind]
end

"Static type of the CelType runtime value denoted by a predeclared identifier."
function denoted_type(name::String)
    name == "int" && return INT_T
    name == "uint" && return UINT_T
    name == "double" && return DOUBLE_T
    name == "bool" && return BOOL_T
    name == "string" && return STRING_T
    name == "bytes" && return BYTES_T
    name == "list" && return list_of(DYN_T)
    name == "map" && return map_of(DYN_T, DYN_T)
    name == "null_type" && return NULL_T
    name == "type" && return type_of(DYN_T)
    name == "google.protobuf.Timestamp" && return TIMESTAMP_T
    name == "google.protobuf.Duration" && return DURATION_T
    return nothing
end

# ------------------------------------------------------------------
# Declarations
# ------------------------------------------------------------------

struct Overload
    id::String
    args::Vector{SType}
    result::SType
    is_receiver::Bool
end

"""
Checker environment: variable and function declarations plus the container.

    CheckerEnv(container="", variables=Dict("x" => CEL.INT_T), functions=Dict())

`functions` maps a CEL function name to a vector of `Overload`s and is merged
over the standard declarations.
"""
struct CheckerEnv
    container::String
    variables::Dict{String,SType}
    functions::Dict{String,Vector{Overload}}
end
function CheckerEnv(; container::String="", variables=Dict{String,SType}(),
    functions=Dict{String,Vector{Overload}}())
    fns = deepcopy(STD_DECLS)
    for (k, v) in functions
        append!(get!(fns, k, Overload[]), v)
    end
    CheckerEnv(container, Dict{String,SType}(variables), fns)
end

struct CheckError <: Exception
    msg::String
end

"Checked expression: the parse result plus inferred types and overload ids."
struct CheckedExpr
    parsed::ParsedExpr
    types::Dict{Int64,SType}
    overloads::Dict{Int64,String}
    refs::Dict{Int64,String}   # resolved qualified names for idents/selects
end

# ------------------------------------------------------------------
# Standard declarations
# ------------------------------------------------------------------

const A_ = param_t("A")
const B_ = param_t("B")

function _std_decls()
    d = Dict{String,Vector{Overload}}()
    ov(name, id, args, result; rcv=false) =
        push!(get!(d, name, Overload[]), Overload(id, collect(args), result, rcv))

    ov("!_", "logical_not", [BOOL_T], BOOL_T)
    ov("-_", "negate_int64", [INT_T], INT_T)
    ov("-_", "negate_double", [DOUBLE_T], DOUBLE_T)
    ov("_?_:_", "conditional", [BOOL_T, A_, A_], A_)
    ov("_&&_", "logical_and", [BOOL_T, BOOL_T], BOOL_T)
    ov("_||_", "logical_or", [BOOL_T, BOOL_T], BOOL_T)
    ov("@not_strictly_false", "not_strictly_false", [BOOL_T], BOOL_T)

    ov("_==_", "equals", [A_, A_], BOOL_T)
    ov("_!=_", "not_equals", [A_, A_], BOOL_T)

    # orderings, incl. cross-type numeric comparisons
    numeric = [(INT_T, "int64"), (UINT_T, "uint64"), (DOUBLE_T, "double")]
    for (opname, opid) in (("_<_", "less"), ("_<=_", "less_equals"),
        ("_>_", "greater"), ("_>=_", "greater_equals"))
        for (t, tn) in [numeric; [(STRING_T, "string"), (BYTES_T, "bytes"), (BOOL_T, "bool"),
            (TIMESTAMP_T, "timestamp"), (DURATION_T, "duration")]]
            ov(opname, "$(opid)_$(tn)", [t, t], BOOL_T)
        end
        for (t1, n1) in numeric, (t2, n2) in numeric
            t1 === t2 && continue
            ov(opname, "$(opid)_$(n1)_$(n2)", [t1, t2], BOOL_T)
        end
    end

    for (t, tn) in [(INT_T, "int64"), (UINT_T, "uint64"), (DOUBLE_T, "double")]
        ov("_+_", "add_$(tn)", [t, t], t)
        ov("_-_", "subtract_$(tn)", [t, t], t)
        ov("_*_", "multiply_$(tn)", [t, t], t)
        ov("_/_", "divide_$(tn)", [t, t], t)
        tn != "double" && ov("_%_", "modulo_$(tn)", [t, t], t)
    end
    ov("_+_", "add_string", [STRING_T, STRING_T], STRING_T)
    ov("_+_", "add_bytes", [BYTES_T, BYTES_T], BYTES_T)
    ov("_+_", "add_list", [list_of(A_), list_of(A_)], list_of(A_))
    ov("_+_", "add_timestamp_duration", [TIMESTAMP_T, DURATION_T], TIMESTAMP_T)
    ov("_+_", "add_duration_timestamp", [DURATION_T, TIMESTAMP_T], TIMESTAMP_T)
    ov("_+_", "add_duration_duration", [DURATION_T, DURATION_T], DURATION_T)
    ov("_-_", "subtract_timestamp_duration", [TIMESTAMP_T, DURATION_T], TIMESTAMP_T)
    ov("_-_", "subtract_timestamp_timestamp", [TIMESTAMP_T, TIMESTAMP_T], DURATION_T)
    ov("_-_", "subtract_duration_duration", [DURATION_T, DURATION_T], DURATION_T)

    ov("_[_]", "index_list", [list_of(A_), INT_T], A_)
    ov("_[_]", "index_map", [map_of(A_, B_), A_], B_)
    ov("@in", "in_list", [A_, list_of(A_)], BOOL_T)
    ov("@in", "in_map", [A_, map_of(A_, B_)], BOOL_T)
    ov("@map_insert", "map_insert", [map_of(A_, B_), A_, B_], map_of(A_, B_))

    for (t, tn) in [(STRING_T, "string"), (BYTES_T, "bytes")]
        ov("size", "size_$(tn)", [t], INT_T)
        ov("size", "$(tn)_size", [t], INT_T; rcv=true)
    end
    ov("size", "size_list", [list_of(A_)], INT_T)
    ov("size", "list_size", [list_of(A_)], INT_T; rcv=true)
    ov("size", "size_map", [map_of(A_, B_)], INT_T)
    ov("size", "map_size", [map_of(A_, B_)], INT_T; rcv=true)

    for f in ("contains", "startsWith", "endsWith")
        ov(f, "string_$(lowercase(f))_string", [STRING_T, STRING_T], BOOL_T; rcv=true)
    end
    ov("matches", "matches_string", [STRING_T, STRING_T], BOOL_T)
    ov("matches", "string_matches_string", [STRING_T, STRING_T], BOOL_T; rcv=true)

    # conversions + identities
    for (t, tn) in [(INT_T, "int64"), (UINT_T, "uint64"), (DOUBLE_T, "double"), (STRING_T, "string")]
        ov("int", "int64_from_$(tn)", [t], INT_T)
        ov("uint", "uint64_from_$(tn)", [t], UINT_T)
        ov("double", "double_from_$(tn)", [t], DOUBLE_T)
        ov("string", "string_from_$(tn)", [t], STRING_T)
    end
    ov("int", "int64_from_timestamp", [TIMESTAMP_T], INT_T)
    ov("int", "int64_from_duration", [DURATION_T], INT_T)
    ov("string", "string_from_bool", [BOOL_T], STRING_T)
    ov("string", "string_from_bytes", [BYTES_T], STRING_T)
    ov("string", "string_from_timestamp", [TIMESTAMP_T], STRING_T)
    ov("string", "string_from_duration", [DURATION_T], STRING_T)
    ov("bool", "bool_from_bool", [BOOL_T], BOOL_T)
    ov("bool", "bool_from_string", [STRING_T], BOOL_T)
    ov("bytes", "bytes_from_bytes", [BYTES_T], BYTES_T)
    ov("bytes", "bytes_from_string", [STRING_T], BYTES_T)
    ov("dyn", "to_dyn", [A_], DYN_T)
    ov("type", "type_of", [A_], type_of(A_))
    ov("timestamp", "timestamp_from_string", [STRING_T], TIMESTAMP_T)
    ov("timestamp", "timestamp_from_int64", [INT_T], TIMESTAMP_T)
    ov("timestamp", "timestamp_from_timestamp", [TIMESTAMP_T], TIMESTAMP_T)
    ov("duration", "duration_from_string", [STRING_T], DURATION_T)
    ov("duration", "duration_from_int64", [INT_T], DURATION_T)
    ov("duration", "duration_from_duration", [DURATION_T], DURATION_T)

    for f in ("getFullYear", "getMonth", "getDayOfYear", "getDayOfMonth", "getDate",
        "getDayOfWeek", "getHours", "getMinutes", "getSeconds", "getMilliseconds")
        ov(f, "timestamp_$(f)", [TIMESTAMP_T], INT_T; rcv=true)
        ov(f, "timestamp_$(f)_with_tz", [TIMESTAMP_T, STRING_T], INT_T; rcv=true)
    end
    for f in ("getHours", "getMinutes", "getSeconds", "getMilliseconds")
        ov(f, "duration_$(f)", [DURATION_T], INT_T; rcv=true)
    end
    return d
end
const STD_DECLS = _std_decls()

# ------------------------------------------------------------------
# Unification
# ------------------------------------------------------------------

"Resolve type params through the substitution map."
function subst(t::SType, subs::Dict{String,SType})
    t.kind == TypeKind.TypeParam && return haskey(subs, t.name) ? subst(subs[t.name], subs) : t
    isempty(t.params) && return t
    return SType(t.kind, [subst(p, subs) for p in t.params], t.name)
end

"""
Unify `formal` (may contain type params) against `actual`. Mutates `subs`
on success. `dyn` unifies with everything.
"""
function unify!(subs::Dict{String,SType}, formal::SType, actual::SType)
    formal = subst(formal, subs)
    actual = subst(actual, subs)
    (formal.kind == TypeKind.Dyn || actual.kind == TypeKind.Dyn) && return true
    actual.kind == TypeKind.Error && return true
    if formal.kind == TypeKind.TypeParam
        formal.name == actual.name || (subs[formal.name] = actual)
        return true
    end
    if actual.kind == TypeKind.TypeParam
        subs[actual.name] = formal
        return true
    end
    formal.kind == actual.kind || return false
    formal.kind in (TypeKind.Message,) && return formal.name == actual.name
    if formal.kind == TypeKind.Type
        # type(T1) and type(T2) always unify: values of different types may
        # be compared (`type(1) == type('a')` is well-typed and false)
        foreach(p -> unify!(subs, p...), zip(formal.params, actual.params))
        return true
    end
    length(formal.params) == length(actual.params) || return false
    for (f, a) in zip(formal.params, actual.params)
        unify!(subs, f, a) || return false
    end
    return true
end

"""
Least common supertype for branch/element joins, over the global
substitution: free type variables unify with the other side ("flexible type
parameter assignment", e.g. `[[], [1]]` is `list(list(int))`).
"""
function join_types(subs::Dict{String,SType}, a::SType, b::SType)
    a = subst(a, subs)
    b = subst(b, subs)
    a == b && return a
    a.kind == TypeKind.Error && return b
    b.kind == TypeKind.Error && return a
    if a.kind == TypeKind.TypeParam
        subs[a.name] = b
        return b
    end
    if b.kind == TypeKind.TypeParam
        subs[b.name] = a
        return a
    end
    a.kind == TypeKind.Null && return b   # null joins with wrapper-ish types; keep permissive
    b.kind == TypeKind.Null && return a
    if a.kind == b.kind && length(a.params) == length(b.params) && a.name == b.name
        return SType(a.kind, [join_types(subs, x, y) for (x, y) in zip(a.params, b.params)], a.name)
    end
    return DYN_T
end

# ------------------------------------------------------------------
# Inference
# ------------------------------------------------------------------

mutable struct CheckState
    env::CheckerEnv
    types::Dict{Int64,SType}
    overloads::Dict{Int64,String}
    refs::Dict{Int64,String}
    scopes::Vector{Dict{String,SType}}   # comprehension variable scopes
    subs::Dict{String,SType}             # global type-variable substitution
    fresh::Int
end

freshvar!(st::CheckState) = param_t("_var$(st.fresh += 1)")

"Replace remaining unbound type variables with dyn (for final reporting)."
function finalize_type(t::SType, subs::Dict{String,SType})
    t = subst(t, subs)
    t.kind == TypeKind.TypeParam && return DYN_T
    isempty(t.params) && return t
    return SType(t.kind, [finalize_type(p, subs) for p in t.params], t.name)
end

"""
    check(env::CheckerEnv, parsed::ParsedExpr) -> CheckedExpr

Type-check a parsed expression. Throws `CheckError` on failure.
"""
function check(env::CheckerEnv, parsed::ParsedExpr)
    st = CheckState(env, Dict{Int64,SType}(), Dict{Int64,String}(), Dict{Int64,String}(),
        Dict{String,SType}[], Dict{String,SType}(), 0)
    infer(st, parsed.expr)
    types = Dict{Int64,SType}(id => finalize_type(t, st.subs) for (id, t) in st.types)
    return CheckedExpr(parsed, types, st.overloads, st.refs)
end
check(env::CheckerEnv, src::AbstractString) = check(env, parse_cel(src))

settype!(st::CheckState, e::CelExpr, t::SType) = (st.types[e.id] = t; t)

function lookup_scope(st::CheckState, name::String)
    for i in length(st.scopes):-1:1
        haskey(st.scopes[i], name) && return st.scopes[i][name]
    end
    return nothing
end

function infer(st::CheckState, e::ConstExpr)
    v = e.value
    t = v isa Bool ? BOOL_T :
        v isa Int64 ? INT_T :
        v isa UInt64 ? UINT_T :
        v isa Float64 ? DOUBLE_T :
        v isa String ? STRING_T :
        v isa CelBytes ? BYTES_T :
        v === nothing ? NULL_T :
        throw(CheckError("unexpected literal type $(typeof(v))"))
    return settype!(st, e, t)
end

"Resolve an identifier or qualified name to a declared variable type."
function resolve_ident(st::CheckState, parts::Vector{String})
    root = parts[1]
    if !startswith(root, ".")
        t = lookup_scope(st, root)
        if t !== nothing
            return (t, 1, root)
        end
    end
    for (qname, k) in name_candidates(st.env.container, parts)
        if haskey(st.env.variables, qname)
            return (st.env.variables[qname], k, qname)
        end
        if k == length(parts)
            dt = denoted_type(qname)
            dt !== nothing && return (type_of(dt), k, qname)
        end
    end
    return nothing
end

function infer(st::CheckState, e::IdentExpr)
    r = resolve_ident(st, [e.name])
    r === nothing && throw(CheckError("undeclared reference to '$(e.name)' (in container '$(st.env.container)')"))
    t, _, qname = r
    st.refs[e.id] = qname
    return settype!(st, e, t)
end

function select_result_type(st::CheckState, opt::SType, field::String)
    opt.kind == TypeKind.Dyn && return DYN_T
    opt.kind == TypeKind.TypeParam && return DYN_T
    opt.kind == TypeKind.Map && return opt.params[2]
    opt.kind == TypeKind.Message && return adapter_field_type(opt.name, field)
    throw(CheckError("type '$(type_name(opt))' does not support field selection"))
end

function infer(st::CheckState, e::SelectExpr)
    if e.test_only
        opt = infer(st, e.operand)
        if !(opt.kind in (TypeKind.Dyn, TypeKind.Map, TypeKind.Message, TypeKind.TypeParam))
            throw(CheckError("has() does not support type '$(type_name(opt))'"))
        end
        return settype!(st, e, BOOL_T)
    end
    path = select_path(e)
    if path !== nothing
        r = resolve_ident(st, path)
        if r !== nothing
            t, k, qname = r
            st.refs[e.id] = qname
            for i in k+1:length(path)
                t = select_result_type(st, t, path[i])
            end
            return settype!(st, e, t)
        end
        # fall through: root must resolve, fields select into it
    end
    opt = infer(st, e.operand)
    return settype!(st, e, select_result_type(st, opt, e.field))
end

function infer(st::CheckState, e::ListExpr)
    # empty literals get a free type variable ("flexible type parameters")
    isempty(e.elements) && return settype!(st, e, list_of(freshvar!(st)))
    t = infer(st, e.elements[1])
    for el in e.elements[2:end]
        t = join_types(st.subs, t, infer(st, el))
    end
    return settype!(st, e, list_of(t))
end

function infer(st::CheckState, e::MapExpr)
    isempty(e.entries) && return settype!(st, e, map_of(freshvar!(st), freshvar!(st)))
    kt = infer(st, e.entries[1].key)
    vt = infer(st, e.entries[1].value)
    for en in e.entries[2:end]
        kt = join_types(st.subs, kt, infer(st, en.key))
        vt = join_types(st.subs, vt, infer(st, en.value))
    end
    return settype!(st, e, map_of(kt, vt))
end

function infer(st::CheckState, e::StructExpr)
    for en in e.entries
        infer(st, en.value)
    end
    # message construction is resolved through the proto adapter; without one
    # the type is unknown
    t = adapter_message_type(st.env.container, e.message_name)
    t === nothing && throw(CheckError("unknown message type '$(e.message_name)'"))
    return settype!(st, e, t)
end

# Adapter hooks for proto type information (extended by the ProtocGen adapter)
adapter_field_type(msgname::String, field::String) = DYN_T
adapter_message_type(container::String, name::String) = nothing

function infer(st::CheckState, e::CallExpr)
    fname = e.fname
    argts = SType[]
    is_receiver_call = false
    if e.target !== nothing
        # namespaced global function spelled as receiver call?
        tpath = select_path(e.target)
        resolved_global = false
        if tpath !== nothing && lookup_scope(st, tpath[1]) === nothing && resolve_ident(st, tpath) === nothing
            for (qname, k) in name_candidates(st.env.container, [tpath; fname])
                k == length(tpath) + 1 || continue
                if haskey(st.env.functions, qname)
                    fname = qname
                    resolved_global = true
                    break
                end
            end
            resolved_global || throw(CheckError("undeclared reference to '$(join(tpath, '.'))'"))
        end
        if !resolved_global
            push!(argts, infer(st, e.target))
            is_receiver_call = true
        end
    end
    for a in e.args
        push!(argts, infer(st, a))
    end

    ovs = nothing
    if !is_receiver_call
        absolute = startswith(fname, ".")
        stripped = absolute ? fname[2:end] : fname
        for prefix in (absolute ? [""] : container_prefixes(st.env.container))
            qname = prefix * stripped
            if haskey(st.env.functions, qname)
                ovs = st.env.functions[qname]
                break
            end
        end
    else
        ovs = get(st.env.functions, fname, nothing)
    end
    ovs === nothing && throw(CheckError("undeclared function '$(fname)'"))

    # try overloads; collect all matches
    result = nothing
    matched_id = nothing
    nmatches = 0
    for ov in ovs
        is_receiver_call && !ov.is_receiver && continue
        # global calls may match receiver decls too (e.g. size) — cel-go keeps
        # them separate; we only enforce the receiver direction
        length(ov.args) == length(argts) || continue
        # instantiate type params freshly per call site; unify into the global
        # substitution transactionally (roll back if the overload mismatches)
        st.fresh += 1
        inst = Dict{String,SType}()
        formals = [instantiate(a, inst, st.fresh) for a in ov.args]
        snapshot = copy(st.subs)
        ok = all(unify!(st.subs, f, a) for (f, a) in zip(formals, argts))
        if !ok
            empty!(st.subs)
            merge!(st.subs, snapshot)
            continue
        end
        r = subst(instantiate(ov.result, inst, st.fresh), st.subs)
        nmatches += 1
        if result === nothing
            result = r
            matched_id = ov.id
        else
            result = join_types(st.subs, result, r)
        end
    end
    if result === nothing
        throw(CheckError("found no matching overload for '$(e.fname)' applied to ($(join(map(type_name, argts), ", ")))"))
    end
    nmatches == 1 && (st.overloads[e.id] = matched_id::String)
    return settype!(st, e, result)
end

"Rename type params to call-site-unique names."
function instantiate(t::SType, inst::Dict{String,SType}, fresh::Int)
    if t.kind == TypeKind.TypeParam
        return get!(inst, t.name) do
            param_t("$(t.name)#$(fresh)")
        end
    end
    isempty(t.params) && return t
    return SType(t.kind, [instantiate(p, inst, fresh) for p in t.params], t.name)
end

function infer(st::CheckState, e::ComprehensionExpr)
    ranget = infer(st, e.iter_range)
    two = !isempty(e.iter_var2)
    (v1t, v2t) = if ranget.kind == TypeKind.List
        two ? (INT_T, ranget.params[1]) : (ranget.params[1], NULL_T)
    elseif ranget.kind == TypeKind.Map
        two ? (ranget.params[1], ranget.params[2]) : (ranget.params[1], NULL_T)
    elseif ranget.kind in (TypeKind.Dyn, TypeKind.TypeParam)
        (DYN_T, DYN_T)
    else
        throw(CheckError("expression of type '$(type_name(ranget))' cannot be the range of a comprehension"))
    end

    accut = infer(st, e.accu_init)
    scope = Dict{String,SType}(e.iter_var => v1t)
    two && (scope[e.iter_var2] = v2t)
    push!(st.scopes, scope)
    # iterate inference of the loop step to a fixpoint of the accumulator type
    for _ in 1:3
        scope[e.accu_var] = accut
        condt = infer(st, e.loop_condition)
        unify!(st.subs, BOOL_T, condt) ||
            throw(CheckError("comprehension condition must be bool, got '$(type_name(condt))'"))
        stept = infer(st, e.loop_step)
        newt = join_types(st.subs, accut, stept)
        newt == accut && break
        accut = newt
    end
    scope[e.accu_var] = accut
    resultt = infer(st, e.result)
    pop!(st.scopes)
    return settype!(st, e, resultt)
end
