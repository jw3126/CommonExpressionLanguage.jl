# Closure-compilation backend: folds the AST bottom-up into nested closures
# `activation -> value`. No eval, no world-age issues; the primary evaluator
# for expressions supplied at runtime.
#
# `sc` threads the lexical scope: comprehension variables declared by
# enclosing nodes. A scoped name resolves directly in the activation and
# shadows container-qualified names (cel-spec name resolution).

"""
Variable bindings for evaluation. `parent` chains comprehension scopes.
"""
struct Activation
    vars::Dict{String,Any}
    parent::Union{Nothing,Activation}
end
Activation(vars::AbstractDict) = Activation(Dict{String,Any}(vars), nothing)

function lookupvar(a::Activation, name::String)
    act = a
    while true
        haskey(act.vars, name) && return Some(act.vars[name])
        act.parent === nothing && return nothing
        act = act.parent
    end
end

"""
Compilation environment.

- `container`: namespace for name resolution (cel-spec "Name Resolution"),
  e.g. `"a.b"` makes `x` resolve against `a.b.x`, `a.x`, `x`.
- `functions`: CEL function name -> Julia function. Merged over `STDLIB`;
  entries here shadow standard functions.
"""
struct Env
    container::String
    functions::Dict{String,Any}
end
function Env(; container::String="", functions=Dict{String,Any}())
    Env(container, merge(STDLIB, Dict{String,Any}(functions)))
end

"Compiled CEL program; call with an AbstractDict of variable bindings."
struct Program
    impl::Function
    source::String
end
(p::Program)(vars::Union{AbstractDict,NamedTuple}=Dict{String,Any}()) =
    p.impl(Activation(to_cel_vars(vars)))
(p::Program)(a::Activation) = p.impl(a)

to_cel_vars(vars::AbstractDict) = Dict{String,Any}(String(k) => to_cel(v) for (k, v) in vars)
to_cel_vars(vars::NamedTuple) = Dict{String,Any}(String(k) => to_cel(v) for (k, v) in pairs(vars))

"Convert a Julia value to its CEL runtime representation (shallow scalars, recursive containers)."
to_cel(x::Union{Int64,UInt64,Float64,Bool,String,Nothing,CelBytes,CelTimestamp,CelDuration,CelType}) = x
to_cel(x::Signed) = Int64(x)
to_cel(x::Unsigned) = UInt64(x)
to_cel(x::AbstractFloat) = Float64(x)
to_cel(x::AbstractString) = String(x)
to_cel(x::AbstractVector) = Any[to_cel(v) for v in x]
to_cel(x::AbstractDict) = OrderedDict{Any,Any}(to_cel(k) => to_cel(v) for (k, v) in x)
to_cel(x) = x  # foreign values (proto messages) pass through to the adapter

"""
    compile(parsed::ParsedExpr; env=Env()) -> Program
    compile(source::AbstractString; env=Env()) -> Program

Compile a CEL expression to a callable program. Evaluation returns the CEL
result value, or a `CelError` value if evaluation errored.
"""
compile(src::AbstractString; env::Env=Env()) = compile(parse_cel(src); env)
function compile(parsed::ParsedExpr; env::Env=Env())
    impl = cnode(env, String[], parsed.expr)
    return Program(impl, parsed.source)
end

"""
    evaluate(source; vars=Dict(), env=Env())

One-shot parse + compile + run.
"""
evaluate(src; vars::Union{AbstractDict,NamedTuple}=Dict{String,Any}(), env::Env=Env()) =
    compile(src; env)(vars)

# ------------------------------------------------------------------
# Name resolution (cel-spec "Name Resolution")
# ------------------------------------------------------------------

"Namespace prefixes to try, most specific first: for container `a.b` -> [\"a.b.\", \"a.\", \"\"]."
function container_prefixes(container::String)
    container == "" && return [""]
    parts = split(container, ".")
    prefixes = String[]
    for i in length(parts):-1:1
        push!(prefixes, join(parts[1:i], ".") * ".")
    end
    push!(prefixes, "")
    return prefixes
end

"""
Candidate resolutions for a dotted path `parts` (root identifier + selected
fields): pairs `(qualified_name, n_path_elements_consumed)`. Tries each
container prefix, longest qualified name first. A leading '.' on the root
identifier forces absolute resolution.
"""
function name_candidates(container::String, parts::Vector{String})
    root = parts[1]
    absolute = startswith(root, ".")
    stripped = absolute ? root[2:end] : root
    prefixes = absolute ? [""] : container_prefixes(container)
    cands = Tuple{String,Int}[]
    for prefix in prefixes
        for k in length(parts):-1:1
            qname = prefix * join([stripped; parts[2:k]], ".")
            push!(cands, (qname, k))
        end
    end
    return cands
end

"Collect the maximal ident-rooted select path, or nothing."
function select_path(e::CelExpr)
    fields = String[]
    node = e
    while node isa SelectExpr && !node.test_only
        pushfirst!(fields, node.field)
        node = node.operand
    end
    node isa IdentExpr || return nothing
    return [node.name; fields]
end

# ------------------------------------------------------------------
# Node compilation
# ------------------------------------------------------------------

function cnode(env::Env, sc::Vector{String}, e::ConstExpr)
    v = e.value
    return _ -> v
end

cnode(env::Env, sc::Vector{String}, e::IdentExpr) = compile_resolution(env, sc, [e.name])

function cnode(env::Env, sc::Vector{String}, e::SelectExpr)
    if e.test_only
        opf = cnode(env, sc, e.operand)
        field = e.field
        return function (act)
            v = opf(act)
            v isa CelError && return v
            return cel_has(v, field)
        end
    end
    path = select_path(e)
    path !== nothing && return compile_resolution(env, sc, path)
    opf = cnode(env, sc, e.operand)
    field = e.field
    return function (act)
        v = opf(act)
        return cel_select(v, field)
    end
end

"Resolve an ident-rooted dotted path against scope, activation + container, and predeclared idents."
function compile_resolution(env::Env, sc::Vector{String}, parts::Vector{String})
    root = parts[1]
    if root in sc
        # Comprehension variable: shadows anything container-qualified.
        rest = parts[2:end]
        return function (act)
            found = lookupvar(act, root)
            found === nothing &&
                return CelError(:no_such_attribute, "undeclared reference to '$(root)'")
            v = something(found)
            for f in rest
                v = cel_select(v, f)
                v isa CelError && return v
            end
            return v
        end
    end

    cands = name_candidates(env.container, parts)
    display_name = join(parts, ".")
    # Predeclared identifiers (type denotations): tried after variables.
    fallback = nothing
    for (qname, k) in cands
        if k == length(parts) && haskey(STD_IDENTS, qname)
            fallback = STD_IDENTS[qname]
            break
        end
    end
    return function (act)
        # Qualified/container names never resolve to comprehension variables:
        # look up in the root activation only.
        base = act
        while base.parent !== nothing
            base = base.parent
        end
        for (qname, k) in cands
            found = lookupvar(base, qname)
            found === nothing && continue
            v = something(found)
            for i in k+1:length(parts)
                v = cel_select(v, parts[i])
                v isa CelError && return v
            end
            return v
        end
        fallback !== nothing && return fallback
        return CelError(:no_such_attribute, "undeclared reference to '$(display_name)'")
    end
end

function cnode(env::Env, sc::Vector{String}, e::ListExpr)
    fs = [cnode(env, sc, el) for el in e.elements]
    n = length(fs)
    return function (act)
        out = Vector{Any}(undef, n)
        for i in 1:n
            v = fs[i](act)
            v isa CelError && return v
            out[i] = v
        end
        return out
    end
end

function cnode(env::Env, sc::Vector{String}, e::MapExpr)
    kfs = [cnode(env, sc, en.key) for en in e.entries]
    vfs = [cnode(env, sc, en.value) for en in e.entries]
    n = length(kfs)
    return function (act)
        m = OrderedDict{Any,Any}()
        for i in 1:n
            k = kfs[i](act)
            k isa CelError && return k
            valid_map_key(k) || return CelError(:invalid_argument, "unsupported map key type: $(typename(k))")
            v = vfs[i](act)
            v isa CelError && return v
            map_has(m, k) && return CelError(:invalid_argument, "Failed with repeated key: $(k)")
            m[k] = v
        end
        return m
    end
end

function cnode(env::Env, sc::Vector{String}, e::StructExpr)
    # Message construction requires a proto adapter; resolved by name at runtime.
    names = [qname for (qname, k) in name_candidates(env.container, [e.message_name]) if k == 1]
    fieldnames = [en.name for en in e.entries]
    vfs = [cnode(env, sc, en.value) for en in e.entries]
    return function (act)
        vals = Vector{Any}(undef, length(vfs))
        for i in eachindex(vfs)
            v = vfs[i](act)
            v isa CelError && return v
            vals[i] = v
        end
        return adapter_new_message(names, fieldnames, vals)
    end
end

function cnode(env::Env, sc::Vector{String}, e::CallExpr)
    fname = e.fname

    # --- special forms: short-circuit + error absorption ---
    if fname == "_&&_" && e.target === nothing && length(e.args) == 2
        lf = cnode(env, sc, e.args[1])
        rf = cnode(env, sc, e.args[2])
        return function (act)
            l = lf(act)
            l === false && return false
            r = rf(act)
            r === false && return false
            l === true && r === true && return true
            l isa CelError && return l
            r isa CelError && return r
            return no_overload("_&&_", l, r)
        end
    elseif fname == "_||_" && e.target === nothing && length(e.args) == 2
        lf = cnode(env, sc, e.args[1])
        rf = cnode(env, sc, e.args[2])
        return function (act)
            l = lf(act)
            l === true && return true
            r = rf(act)
            r === true && return true
            l === false && r === false && return false
            l isa CelError && return l
            r isa CelError && return r
            return no_overload("_||_", l, r)
        end
    elseif fname == "_?_:_" && e.target === nothing && length(e.args) == 3
        cf = cnode(env, sc, e.args[1])
        tf = cnode(env, sc, e.args[2])
        ff = cnode(env, sc, e.args[3])
        return function (act)
            c = cf(act)
            c === true && return tf(act)
            c === false && return ff(act)
            c isa CelError && return c
            return no_overload("_?_:_", c)
        end
    elseif fname == "@not_strictly_false" && length(e.args) == 1
        af = cnode(env, sc, e.args[1])
        return function (act)
            v = af(act)
            return v === false ? false : true
        end
    end

    # --- namespaced global call spelled as a receiver call: a.b.f(x) ---
    if e.target !== nothing
        tpath = select_path(e.target)
        if tpath !== nothing && !(tpath[1] in sc)
            for (qname, k) in name_candidates(env.container, [tpath; fname])
                k == length(tpath) + 1 || continue
                if haskey(env.functions, qname)
                    return compile_strict_call(env, sc, qname, env.functions[qname], e.args)
                end
            end
        end
        # receiver call: target becomes the first argument
        f = get(env.functions, fname, nothing)
        args = CelExpr[e.target; e.args]
        f === nothing && return _ -> CelError(:unknown_function, "unknown function '$(fname)'")
        return compile_strict_call(env, sc, fname, f, args)
    end

    # --- plain global call (container-qualified lookup) ---
    absolute = startswith(fname, ".")
    stripped = absolute ? fname[2:end] : fname
    for prefix in (absolute ? [""] : container_prefixes(env.container))
        qname = prefix * stripped
        if haskey(env.functions, qname)
            return compile_strict_call(env, sc, qname, env.functions[qname], e.args)
        end
    end
    return _ -> CelError(:unknown_function, "unknown function '$(fname)'")
end

"Strict call: arguments evaluated left to right, first error wins."
function compile_strict_call(env::Env, sc::Vector{String}, fname::String, f, argexprs::Vector{CelExpr})
    afs = [cnode(env, sc, a) for a in argexprs]
    n = length(afs)
    if n == 1
        a1 = afs[1]
        return function (act)
            x = a1(act)
            x isa CelError && return x
            return call_fn(f, fname, x)
        end
    elseif n == 2
        a1, a2 = afs[1], afs[2]
        return function (act)
            x = a1(act)
            x isa CelError && return x
            y = a2(act)
            y isa CelError && return y
            return call_fn(f, fname, x, y)
        end
    else
        return function (act)
            vals = Vector{Any}(undef, n)
            for i in 1:n
                v = afs[i](act)
                v isa CelError && return v
                vals[i] = v
            end
            return call_fn(f, fname, vals...)
        end
    end
end

"Invoke a table function; a MethodError on the outermost call means no overload."
function call_fn(f, fname, args...)
    try
        return f(args...)
    catch err
        if err isa MethodError && err.f === f
            return no_overload(fname, args...)
        end
        rethrow()
    end
end

# ------------------------------------------------------------------
# Comprehensions
# ------------------------------------------------------------------

function cnode(env::Env, sc::Vector{String}, e::ComprehensionExpr)
    two = !isempty(e.iter_var2)
    loop_sc = two ? [sc; e.iter_var; e.iter_var2; e.accu_var] : [sc; e.iter_var; e.accu_var]
    result_sc = [sc; e.accu_var]

    rangef = cnode(env, sc, e.iter_range)
    initf = cnode(env, sc, e.accu_init)
    condf = cnode(env, loop_sc, e.loop_condition)
    stepf = cnode(env, loop_sc, e.loop_step)
    resultf = cnode(env, result_sc, e.result)
    iter_var = e.iter_var
    iter_var2 = e.iter_var2
    accu_var = e.accu_var

    return function (act)
        range = rangef(act)
        range isa CelError && return range
        items = if range isa AbstractVector
            two ? Any[(Int64(i - 1), v) for (i, v) in enumerate(range)] :
                  Any[v for v in range]
        elseif range isa AbstractDict
            two ? Any[(k, v) for (k, v) in range] : Any[k for k in keys(range)]
        else
            return no_overload("comprehension range", range)
        end

        accu = initf(act)
        accu isa CelError && return accu
        vars = Dict{String,Any}()
        child = Activation(vars, act)
        for item in items
            vars[accu_var] = accu
            if two
                vars[iter_var] = item[1]
                vars[iter_var2] = item[2]
            else
                vars[iter_var] = item
            end
            c = condf(child)
            c isa CelError && return c
            c === false && break
            c === true || return no_overload("comprehension condition", c)
            # Errors in the step become the accumulator: later iterations may
            # still absorb them (e.g. `all` turning false), per spec.
            accu = stepf(child)
        end
        # Result sees only the accumulator, not the iteration variables.
        return resultf(Activation(Dict{String,Any}(accu_var => accu), act))
    end
end
