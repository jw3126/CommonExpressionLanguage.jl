# AST mirroring the structure of `cel.expr.syntax.Expr` from cel-spec.
#
# Every node carries a unique positive `id`. Source byte offsets are kept
# out-of-band in `ParsedExpr.positions` (id => offset), matching the
# SourceInfo design of the spec so checker metadata can also key on ids.

abstract type CelExpr end

"""
Literal constant. `value` is one of:
`Int64`, `UInt64`, `Float64`, `Bool`, `String`, `CelBytes`, `Nothing` (null).
"""
struct ConstExpr <: CelExpr
    id::Int64
    value::Any
end

"""
Identifier reference. A leading `'.'` in `name` marks an absolute
(root-scoped) reference like `.a.b` that must skip container resolution.
"""
struct IdentExpr <: CelExpr
    id::Int64
    name::String
end

"""
Field selection `operand.field`. With `test_only` set this is the expansion
of the `has(operand.field)` macro and evaluates to a presence test.
"""
struct SelectExpr <: CelExpr
    id::Int64
    operand::CelExpr
    field::String
    test_only::Bool
end

"""
Function call. Operators use their canonical CEL function names
(`_+_`, `_==_`, `_&&_`, `!_`, `-_`, `_?_:_`, `_[_]`, `@in`, ...).
`target === nothing` for global calls, otherwise a receiver-style call
`target.fname(args...)`.
"""
struct CallExpr <: CelExpr
    id::Int64
    target::Union{Nothing,CelExpr}
    fname::String
    args::Vector{CelExpr}
end

"List literal `[e1, e2, ...]`."
struct ListExpr <: CelExpr
    id::Int64
    elements::Vector{CelExpr}
end

struct MapEntry
    id::Int64
    key::CelExpr
    value::CelExpr
end

"Map literal `{k1: v1, ...}`."
struct MapExpr <: CelExpr
    id::Int64
    entries::Vector{MapEntry}
end

struct FieldEntry
    id::Int64
    name::String
    value::CelExpr
end

"Message construction `pkg.Msg{field: value, ...}`. `message_name` may have a leading `'.'` (absolute)."
struct StructExpr <: CelExpr
    id::Int64
    message_name::String
    entries::Vector{FieldEntry}
end

"""
Fold/comprehension node, the expansion target of the `all`/`exists`/
`exists_one`/`map`/`filter` macros. Semantics per cel-spec:

    accu = eval(accu_init)
    for iter_var in eval(iter_range):        # (iter_var, iter_var2) for two-variable macros
        if !eval(loop_condition): break
        accu = eval(loop_step)
    return eval(result)

`iter_var2` is empty for single-variable comprehensions; when non-empty,
`iter_var` binds keys/indices and `iter_var2` binds values.
"""
struct ComprehensionExpr <: CelExpr
    id::Int64
    iter_var::String
    iter_var2::String
    iter_range::CelExpr
    accu_var::String
    accu_init::CelExpr
    loop_condition::CelExpr
    loop_step::CelExpr
    result::CelExpr
end

"Parse result: root expression plus source text and id => byte-offset map."
struct ParsedExpr
    expr::CelExpr
    source::String
    positions::Dict{Int64,Int}
end

# The accumulator variable name used by macro expansions, per cel-spec.
const ACCU_VAR = "__result__"
