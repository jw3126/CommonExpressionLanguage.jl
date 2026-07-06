# Julia-source transpiler backend: AST -> Base.Expr calling the ops.jl
# semantics helpers. This is the protovalidate path: constraint expressions
# known at proto-codegen time are emitted as ordinary Julia code into
# generated files (no runtime compilation, precompilable, JIT-specialized).
#
# CEL variables are resolved, in order:
#   1. comprehension variables        -> Julia locals introduced by the loop
#   2. `varmap` entries               -> caller-supplied Julia expressions
#                                        (e.g. "this" => :(msg.name))
#   3. the bindings dict `varsdict`   -> runtime lookup (dynamic fallback);
#                                        pass `varsdict=nothing` to disable
#                                        and turn unknowns into errors.

const CELMOD = @__MODULE__

_ref(f::Symbol) = GlobalRef(CELMOD, f)

struct TranspileCtx
    env::Env
    varmap::Dict{String,Any}            # CEL name -> Julia Expr
    varsdict::Union{Symbol,Nothing}     # symbol of an AbstractDict in scope
    locals::Dict{String,Symbol}         # comprehension vars -> Julia locals
end

"""
    transpile(parsed_or_source; env=Env(), varmap=Dict(), varsdict=:vars) -> Expr

Translate a CEL expression to a Julia expression. The result evaluates to
the CEL value, or a `CelError` value on evaluation errors — the same
semantics as the closure backend.

`varmap` maps CEL variable names to Julia expressions (for code generators:
`"this" => :(msg.name)`). Other variables are looked up at runtime in the
`AbstractDict` named by `varsdict` (default `:vars`), or fail if
`varsdict=nothing`.

See `transpile_function` for a ready-to-`eval` function definition.
"""
transpile(src::AbstractString; kw...) = transpile(parse_cel(src); kw...)
function transpile(parsed::ParsedExpr; env::Env=Env(),
    varmap=Dict{String,Any}(), varsdict::Union{Symbol,Nothing}=:vars)
    ctx = TranspileCtx(env, Dict{String,Any}(varmap), varsdict, Dict{String,Symbol}())
    return tnode(ctx, parsed.expr)
end

"""
    transpile_function(parsed_or_source; fname=gensym, env, varmap, varsdict=:vars) -> Expr

Wrap `transpile` output in a `function fname(vars::AbstractDict) ... end`
definition (or with no argument if `varsdict=nothing`).
"""
function transpile_function(parsed; fname::Symbol=gensym("cel_program"), env::Env=Env(),
    varmap=Dict{String,Any}(), varsdict::Union{Symbol,Nothing}=:vars)
    body = transpile(parsed isa AbstractString ? parse_cel(parsed) : parsed; env, varmap, varsdict)
    args = varsdict === nothing ? [] : [:($varsdict::AbstractDict)]
    return Expr(:function, Expr(:call, fname, args...), Expr(:block, body))
end

# ------------------------------------------------------------------
# Node translation
# ------------------------------------------------------------------

function tnode(ctx::TranspileCtx, e::ConstExpr)
    v = e.value
    v isa CelBytes && return Expr(:call, _ref(:CelBytes), v.data)
    return v
end

tnode(ctx::TranspileCtx, e::IdentExpr) = resolve_expr(ctx, [e.name])

function tnode(ctx::TranspileCtx, e::SelectExpr)
    if e.test_only
        return Expr(:call, _ref(:cel_has), tnode(ctx, e.operand), e.field)
    end
    path = select_path(e)
    path !== nothing && return resolve_expr(ctx, path)
    return Expr(:call, _ref(:cel_select), tnode(ctx, e.operand), e.field)
end

function resolve_expr(ctx::TranspileCtx, parts::Vector{String})
    root = parts[1]
    # comprehension variables (transpile-time scoping)
    if haskey(ctx.locals, root) && !startswith(root, ".")
        ex = ctx.locals[root]::Any
        for f in parts[2:end]
            ex = Expr(:call, _ref(:cel_select), ex, f)
        end
        return ex
    end
    cands = name_candidates(ctx.env.container, parts)
    # transpile-time varmap resolution (longest candidate wins, like runtime)
    for (qname, k) in cands
        haskey(ctx.varmap, qname) || continue
        ex = ctx.varmap[qname]
        for i in k+1:length(parts)
            ex = Expr(:call, _ref(:cel_select), ex, parts[i])
        end
        return ex
    end
    fallback = nothing
    for (qname, k) in cands
        if k == length(parts) && haskey(STD_IDENTS, qname)
            fallback = STD_IDENTS[qname]
            break
        end
    end
    if ctx.varsdict === nothing
        fallback !== nothing && return Expr(:call, _ref(:CelType), fallback.name)
        return Expr(:call, _ref(:CelError), QuoteNode(:no_such_attribute),
            "undeclared reference to '$(join(parts, '.'))'")
    end
    fallback_ex = fallback === nothing ? nothing : Expr(:call, _ref(:CelType), fallback.name)
    return Expr(:call, _ref(:_resolve_path), ctx.varsdict,
        Tuple(cands), parts, fallback_ex)
end

tnode(ctx::TranspileCtx, e::ListExpr) =
    Expr(:call, _ref(:_mklist), (tnode(ctx, el) for el in e.elements)...)

tnode(ctx::TranspileCtx, e::MapExpr) =
    Expr(:call, _ref(:_mkmap),
        Iterators.flatten((tnode(ctx, en.key), tnode(ctx, en.value)) for en in e.entries)...)

function tnode(ctx::TranspileCtx, e::StructExpr)
    names = [qname for (qname, k) in name_candidates(ctx.env.container, [e.message_name]) if k == 1]
    fieldnames = [en.name for en in e.entries]
    vals = Expr(:call, _ref(:_mklist), (tnode(ctx, en.value) for en in e.entries)...)
    v = gensym("fields")
    return Expr(:block,
        :($v = $vals),
        :($v isa $(_ref(:CelError)) ? $v :
          $(_ref(:adapter_new_message))($names, $fieldnames, $v)))
end

function tnode(ctx::TranspileCtx, e::CallExpr)
    fname = e.fname

    if fname == "_&&_" && e.target === nothing && length(e.args) == 2
        l, r = gensym("l"), gensym("r")
        return quote
            let $l = $(tnode(ctx, e.args[1]))
                $l === false ? false : let $r = $(tnode(ctx, e.args[2]))
                    $r === false ? false : $(_ref(:_and_join))($l, $r)
                end
            end
        end
    elseif fname == "_||_" && e.target === nothing && length(e.args) == 2
        l, r = gensym("l"), gensym("r")
        return quote
            let $l = $(tnode(ctx, e.args[1]))
                $l === true ? true : let $r = $(tnode(ctx, e.args[2]))
                    $r === true ? true : $(_ref(:_or_join))($l, $r)
                end
            end
        end
    elseif fname == "_?_:_" && e.target === nothing && length(e.args) == 3
        c = gensym("cond")
        return quote
            let $c = $(tnode(ctx, e.args[1]))
                $c === true ? $(tnode(ctx, e.args[2])) :
                $c === false ? $(tnode(ctx, e.args[3])) :
                $c isa $(_ref(:CelError)) ? $c : $(_ref(:no_overload))("_?_:_", $c)
            end
        end
    elseif fname == "@not_strictly_false" && length(e.args) == 1
        v = gensym("nsf")
        return :(let $v = $(tnode(ctx, e.args[1]))
            $v === false ? false : true
        end)
    end

    # namespaced global call spelled as receiver call
    if e.target !== nothing
        tpath = select_path(e.target)
        if tpath !== nothing && !haskey(ctx.locals, tpath[1])
            for (qname, k) in name_candidates(ctx.env.container, [tpath; fname])
                k == length(tpath) + 1 || continue
                if haskey(ctx.env.functions, qname)
                    return strict_call_expr(ctx, qname, ctx.env.functions[qname], e.args)
                end
            end
        end
        f = get(ctx.env.functions, fname, nothing)
        f === nothing && return Expr(:call, _ref(:CelError), QuoteNode(:unknown_function),
            "unknown function '$(fname)'")
        return strict_call_expr(ctx, fname, f, CelExpr[e.target; e.args])
    end

    absolute = startswith(fname, ".")
    stripped = absolute ? fname[2:end] : fname
    for prefix in (absolute ? [""] : container_prefixes(ctx.env.container))
        qname = prefix * stripped
        if haskey(ctx.env.functions, qname)
            return strict_call_expr(ctx, qname, ctx.env.functions[qname], e.args)
        end
    end
    return Expr(:call, _ref(:CelError), QuoteNode(:unknown_function), "unknown function '$(fname)'")
end

"Reference a function printably when possible, else splice the value."
function fun_ref(f)
    m = parentmodule(f)
    n = nameof(f)
    if isdefined(m, n) && getproperty(m, n) === f
        return GlobalRef(m, n)
    end
    return f
end

"Strict call: let-bind arguments left to right, first error short-circuits."
function strict_call_expr(ctx::TranspileCtx, fname::String, f, argexprs::Vector{CelExpr})
    syms = [gensym("a$i") for i in eachindex(argexprs)]
    # stdlib functions have no_overload fallback methods and never throw
    # MethodError; user functions go through call_fn
    core = if f isa Function && parentmodule(f) === CELMOD
        Expr(:call, fun_ref(f), syms...)
    else
        Expr(:call, _ref(:call_fn), fun_ref(f), fname, syms...)
    end
    ex = core
    for i in length(argexprs):-1:1
        ex = Expr(:let, Expr(:(=), syms[i], tnode(ctx, argexprs[i])),
            Expr(:if, :($(syms[i]) isa $(_ref(:CelError))), syms[i], ex))
    end
    return ex
end

# ------------------------------------------------------------------
# Comprehensions -> loops
# ------------------------------------------------------------------

function tnode(ctx::TranspileCtx, e::ComprehensionExpr)
    two = !isempty(e.iter_var2)
    v1 = gensym(e.iter_var)
    v2 = two ? gensym(e.iter_var2) : gensym("unused")
    accu = gensym(e.accu_var)
    item = gensym("item")
    items = gensym("items")
    cond = gensym("cond")

    inner = TranspileCtx(ctx.env, ctx.varmap, ctx.varsdict, copy(ctx.locals))
    inner.locals[e.iter_var] = v1
    two && (inner.locals[e.iter_var2] = v2)
    inner.locals[e.accu_var] = accu

    result_ctx = TranspileCtx(ctx.env, ctx.varmap, ctx.varsdict, copy(ctx.locals))
    result_ctx.locals[e.accu_var] = accu

    bindvars = two ?
               Expr(:block, :($v1 = $item[1]), :($v2 = $item[2])) :
               :($v1 = $item)

    return quote
        (function ()
            $items = $(_ref(:iter_items))($(tnode(ctx, e.iter_range)), $two)
            $items isa $(_ref(:CelError)) && return $items
            $accu = $(tnode(ctx, e.accu_init))
            $accu isa $(_ref(:CelError)) && return $accu
            for $item in $items
                $bindvars
                $cond = $(tnode(inner, e.loop_condition))
                $cond isa $(_ref(:CelError)) && return $cond
                $cond === false && break
                $cond === true || return $(_ref(:no_overload))("comprehension condition", $cond)
                $accu = $(tnode(inner, e.loop_step))
            end
            return $(tnode(result_ctx, e.result))
        end)()
    end
end
