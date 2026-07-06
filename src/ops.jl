# CEL operator/function semantics. Both evaluation backends (closure
# compiler and Julia-source transpiler) emit calls into these helpers.
#
# CEL semantics differ from Julia's:
#   - int/uint arithmetic is overflow-CHECKED (error, not wraparound)
#   - int and uint are distinct types with exact cross-type comparison
#   - `1 == 1.0` is true (heterogeneous numeric equality); other cross-type
#     equality is false, never an error
#   - errors are values (CelError) propagated by strict functions
#
# Julia's built-in mixed int/float comparisons (==, <, <=) are exact
# (no rounding through promotion), so we can use them directly; only
# Int64/UInt64 pairs need custom handling (Julia would promote to UInt64).

const ERR_OVERFLOW = CelError(:overflow, "math overflow")
const ERR_DIV_ZERO = CelError(:divide_by_zero, "divide by zero")
const ERR_MOD_ZERO = CelError(:modulus_by_zero, "modulus by zero")

typename(x) = cel_typeof(x) isa CelType ? cel_typeof(x).name : string(typeof(x))

no_overload(fname, args...) =
    CelError(:no_matching_overload,
        "found no matching overload for '$(fname)' applied to ($(join(map(typename, args), ", ")))")

# ------------------------------------------------------------------
# Arithmetic
# ------------------------------------------------------------------

function cel_add(x::Int64, y::Int64)
    r, ov = Base.add_with_overflow(x, y)
    return ov ? ERR_OVERFLOW : r
end
function cel_add(x::UInt64, y::UInt64)
    r, ov = Base.add_with_overflow(x, y)
    return ov ? ERR_OVERFLOW : r
end
cel_add(x::Float64, y::Float64) = x + y
cel_add(x::String, y::String) = x * y
cel_add(x::CelBytes, y::CelBytes) = CelBytes(vcat(x.data, y.data))
cel_add(x::AbstractVector, y::AbstractVector) = vcat(Vector{Any}(x), Vector{Any}(y))
cel_add(x, y) = no_overload("_+_", x, y)

function cel_sub(x::Int64, y::Int64)
    r, ov = Base.sub_with_overflow(x, y)
    return ov ? ERR_OVERFLOW : r
end
function cel_sub(x::UInt64, y::UInt64)
    r, ov = Base.sub_with_overflow(x, y)
    return ov ? ERR_OVERFLOW : r
end
cel_sub(x::Float64, y::Float64) = x - y
cel_sub(x, y) = no_overload("_-_", x, y)

function cel_mul(x::Int64, y::Int64)
    r, ov = Base.mul_with_overflow(x, y)
    return ov ? ERR_OVERFLOW : r
end
function cel_mul(x::UInt64, y::UInt64)
    r, ov = Base.mul_with_overflow(x, y)
    return ov ? ERR_OVERFLOW : r
end
cel_mul(x::Float64, y::Float64) = x * y
cel_mul(x, y) = no_overload("_*_", x, y)

function cel_div(x::Int64, y::Int64)
    y == 0 && return ERR_DIV_ZERO
    (x == typemin(Int64) && y == -1) && return ERR_OVERFLOW
    return div(x, y)  # truncated division per spec
end
cel_div(x::UInt64, y::UInt64) = y == 0 ? ERR_DIV_ZERO : div(x, y)
cel_div(x::Float64, y::Float64) = x / y
cel_div(x, y) = no_overload("_/_", x, y)

function cel_mod(x::Int64, y::Int64)
    y == 0 && return ERR_MOD_ZERO
    (x == typemin(Int64) && y == -1) && return Int64(0)
    return rem(x, y)  # sign follows dividend per spec
end
cel_mod(x::UInt64, y::UInt64) = y == 0 ? ERR_MOD_ZERO : rem(x, y)
cel_mod(x, y) = no_overload("_%_", x, y)

function cel_neg(x::Int64)
    x == typemin(Int64) && return ERR_OVERFLOW
    return -x
end
cel_neg(x::Float64) = -x
cel_neg(x) = no_overload("-_", x)

cel_not(x::Bool) = !x
cel_not(x) = no_overload("!_", x)

# ------------------------------------------------------------------
# Comparison (ordering)
# ------------------------------------------------------------------

# Cross-type int/uint <-> double ordering follows cel-go: clamp the double
# to the integer range, otherwise compare AS DOUBLES (lossy near 2^63/2^64 —
# conformance tests this, e.g. 9223372036854775807 < 9223372036854775808.0
# is false). Returns -1/0/1, or `nothing` for NaN (all orderings false).
function _cmp_double_int(d::Float64, i::Int64)
    isnan(d) && return nothing
    d < -9.223372036854776e18 && return -1   # < MinInt64
    d > 9.223372036854776e18 && return 1     # > MaxInt64 rounded up to 2^63
    return _cmp(d, Float64(i))
end
function _cmp_double_uint(d::Float64, u::UInt64)
    isnan(d) && return nothing
    d < 0 && return -1
    d > 1.8446744073709552e19 && return 1    # > MaxUint64 rounded up to 2^64
    return _cmp(d, Float64(u))
end
_cmp(a, b) = a < b ? -1 : a > b ? 1 : 0

for (f, op) in ((:cel_lt, :<), (:cel_le, :<=))
    negf = f == :cel_lt ? :cel_gt : :cel_ge
    @eval begin
        # same-type
        $f(x::Int64, y::Int64) = $op(x, y)
        $f(x::UInt64, y::UInt64) = $op(x, y)
        $f(x::Float64, y::Float64) = $op(x, y)
        $f(x::Bool, y::Bool) = $op(x, y)
        $f(x::String, y::String) = $op(x, y)
        $f(x::CelBytes, y::CelBytes) = $op(_bytescmp(x.data, y.data), 0)
        # cross-type numeric (see _cmp_double_int notes)
        $f(x::Int64, y::Float64) = (c = _cmp_double_int(y, x); c === nothing ? false : $op(-c, 0))
        $f(x::Float64, y::Int64) = (c = _cmp_double_int(x, y); c === nothing ? false : $op(c, 0))
        $f(x::UInt64, y::Float64) = (c = _cmp_double_uint(y, x); c === nothing ? false : $op(-c, 0))
        $f(x::Float64, y::UInt64) = (c = _cmp_double_uint(x, y); c === nothing ? false : $op(c, 0))
        $f(x::Int64, y::UInt64) = x < 0 || $op(UInt64(x), y)
        $f(x::UInt64, y::Int64) = y >= 0 && $op(x, UInt64(y))
        $f(x, y) = no_overload($(f == :cel_lt ? "_<_" : "_<=_"), x, y)
        # duals defined via the mirrored operator
        $negf(x, y) = (r = $f(y, x); r)
    end
end

function _bytescmp(a::Vector{UInt8}, b::Vector{UInt8})
    n = min(length(a), length(b))
    for i in 1:n
        a[i] != b[i] && return a[i] < b[i] ? -1 : 1
    end
    return cmp(length(a), length(b))
end

# ------------------------------------------------------------------
# Equality (total: cross-type equality is false, never an error)
# ------------------------------------------------------------------

cel_eq(x::Int64, y::Int64) = x == y
cel_eq(x::UInt64, y::UInt64) = x == y
cel_eq(x::Float64, y::Float64) = x == y
cel_eq(x::Int64, y::Float64) = x == y      # exact in Julia
cel_eq(x::Float64, y::Int64) = x == y
cel_eq(x::UInt64, y::Float64) = x == y
cel_eq(x::Float64, y::UInt64) = x == y
cel_eq(x::Int64, y::UInt64) = x >= 0 && UInt64(x) == y
cel_eq(x::UInt64, y::Int64) = y >= 0 && x == UInt64(y)
cel_eq(x::Bool, y::Bool) = x == y
cel_eq(x::String, y::String) = x == y
cel_eq(x::CelBytes, y::CelBytes) = x.data == y.data
cel_eq(x::Nothing, y::Nothing) = true
cel_eq(x::CelType, y::CelType) = x.name == y.name

function cel_eq(x::AbstractVector, y::AbstractVector)
    length(x) == length(y) || return false
    for i in eachindex(x)
        r = cel_eq(x[i], y[i])
        r isa CelError && return r
        r || return false
    end
    return true
end

function cel_eq(x::AbstractDict, y::AbstractDict)
    length(x) == length(y) || return false
    for (k, v) in x
        found = map_get(y, k)
        found === nothing && return false
        r = cel_eq(v, something(found))
        r isa CelError && return r
        r || return false
    end
    return true
end

cel_eq(x, y) = false  # distinct runtime types

function cel_ne(x, y)
    r = cel_eq(x, y)
    return r isa CelError ? r : !r
end

# ------------------------------------------------------------------
# Maps: heterogeneous numeric key lookup (1, 1u and 1.0 are the same key)
# ------------------------------------------------------------------

valid_map_key(k) = k isa Int64 || k isa UInt64 || k isa Bool || k isa String

"Alternate numeric representations of a key, for cross-type lookup."
function _alt_keys(k)
    if k isa Int64
        return k >= 0 ? Any[UInt64(k)] : Any[]
    elseif k isa UInt64
        return k <= UInt64(typemax(Int64)) ? Any[Int64(k)] : Any[]
    elseif k isa Float64
        if isinteger(k)
            alts = Any[]
            typemin(Int64) <= k <= typemax(Int64) && push!(alts, Int64(k))
            0 <= k <= typemax(UInt64) && push!(alts, UInt64(k))
            return alts
        end
        return Any[]
    end
    return Any[]
end

"Lookup with CEL key equality. Returns Some(value) or nothing."
function map_get(m::AbstractDict, k)
    haskey(m, k) && return Some(m[k])
    for ak in _alt_keys(k)
        haskey(m, ak) && return Some(m[ak])
    end
    return nothing
end

map_has(m::AbstractDict, k) = map_get(m, k) !== nothing

# ------------------------------------------------------------------
# Indexing and membership
# ------------------------------------------------------------------

function cel_index(l::AbstractVector, i::Int64)
    0 <= i < length(l) || return CelError(:index_out_of_range, "index out of bounds: $(i)")
    return l[i+1]
end
function cel_index(l::AbstractVector, i::UInt64)
    i <= UInt64(typemax(Int64)) || return CelError(:index_out_of_range, "index out of bounds: $(i)")
    return cel_index(l, Int64(i))
end
function cel_index(l::AbstractVector, i::Float64)
    isinteger(i) && typemin(Int64) <= i <= typemax(Int64) ||
        return CelError(:invalid_argument, "invalid list index: $(i)")
    return cel_index(l, Int64(i))
end
function cel_index(m::AbstractDict, k)
    (valid_map_key(k) || k isa Float64) || return no_overload("_[_]", m, k)
    v = map_get(m, k)
    v === nothing && return CelError(:no_such_key, "no such key: $(k)")
    return something(v)
end
cel_index(x, i) = no_overload("_[_]", x, i)

function cel_in(x, l::AbstractVector)
    for e in l
        r = cel_eq(x, e)
        r isa CelError && return r
        r === true && return true
    end
    return false
end
cel_in(x, m::AbstractDict) = map_has(m, x)
cel_in(x, c) = no_overload("@in", x, c)

# ------------------------------------------------------------------
# Field selection / presence
# ------------------------------------------------------------------

function cel_select(m::AbstractDict, field::String)
    v = map_get(m, field)
    v === nothing && return CelError(:no_such_key, "no such key: $(field)")
    return something(v)
end
cel_select(x::Nothing, field::String) = CelError(:no_matching_overload, "cannot select field $(field) of null")
cel_select(e::CelError, field::String) = e
cel_select(x, field::String) = adapter_select(x, field)

cel_has(m::AbstractDict, field::String) = map_has(m, field)
cel_has(x::Nothing, field::String) = CelError(:no_matching_overload, "cannot test presence on null")
cel_has(e::CelError, field::String) = e
cel_has(x, field::String) = adapter_has(x, field)

# adapter fallbacks (overridden for proto messages by the ProtocGen adapter)
adapter_select(x, field::String) = no_overload("select", x)
adapter_has(x, field::String) = no_overload("has", x)

# ------------------------------------------------------------------
# size
# ------------------------------------------------------------------

cel_size(s::String) = Int64(length(s))          # code points
cel_size(b::CelBytes) = Int64(length(b.data))
cel_size(l::AbstractVector) = Int64(length(l))
cel_size(m::AbstractDict) = Int64(length(m))
cel_size(x) = no_overload("size", x)

# ------------------------------------------------------------------
# String functions
# ------------------------------------------------------------------

cel_contains(s::String, sub::String) = occursin(sub, s)
cel_contains(x, y) = no_overload("contains", x, y)
cel_starts_with(s::String, pre::String) = startswith(s, pre)
cel_starts_with(x, y) = no_overload("startsWith", x, y)
cel_ends_with(s::String, suf::String) = endswith(s, suf)
cel_ends_with(x, y) = no_overload("endsWith", x, y)

function cel_matches(s::String, pattern::String)
    re = try
        Regex(pattern)
    catch
        return CelError(:invalid_argument, "invalid regex: $(pattern)")
    end
    return try
        occursin(re, s)
    catch
        CelError(:invalid_argument, "regex match failed")
    end
end
cel_matches(x, y) = no_overload("matches", x, y)

# ------------------------------------------------------------------
# Type conversions
# ------------------------------------------------------------------

cel_to_int(x::Int64) = x
cel_to_int(x::UInt64) = x <= UInt64(typemax(Int64)) ? Int64(x) : ERR_OVERFLOW
function cel_to_int(x::Float64)
    # cel-go doubleToInt64Checked: bounds are EXCLUSIVE (int(-2^63.0) errors)
    (isnan(x) || x >= 9.223372036854776e18 || x <= -9.223372036854776e18) && return ERR_OVERFLOW
    return unsafe_trunc(Int64, x)
end
function cel_to_int(x::String)
    v = tryparse(Int64, x)
    return v === nothing ? CelError(:invalid_argument, "cannot convert string to int: $(repr(x))") : v
end
cel_to_int(x::CelTimestamp) = x.seconds
cel_to_int(x::CelDuration) = x.seconds  # not standard, removed if conformance disagrees
cel_to_int(x) = no_overload("int", x)

cel_to_uint(x::UInt64) = x
cel_to_uint(x::Int64) = x >= 0 ? UInt64(x) : ERR_OVERFLOW
function cel_to_uint(x::Float64)
    (isnan(x) || x >= 1.8446744073709552e19 || x < 0) && return ERR_OVERFLOW
    return unsafe_trunc(UInt64, x)
end
function cel_to_uint(x::String)
    v = tryparse(UInt64, x)
    return v === nothing ? CelError(:invalid_argument, "cannot convert string to uint: $(repr(x))") : v
end
cel_to_uint(x) = no_overload("uint", x)

cel_to_double(x::Float64) = x
cel_to_double(x::Int64) = Float64(x)
cel_to_double(x::UInt64) = Float64(x)
function cel_to_double(x::String)
    v = tryparse(Float64, x)
    return v === nothing ? CelError(:invalid_argument, "cannot convert string to double: $(repr(x))") : v
end
cel_to_double(x) = no_overload("double", x)

function cel_to_bool(x::String)
    x in ("true", "True", "TRUE", "t", "1") && return true
    x in ("false", "False", "FALSE", "f", "0") && return false
    return CelError(:invalid_argument, "cannot convert string to bool: $(repr(x))")
end
cel_to_bool(x::Bool) = x
cel_to_bool(x) = no_overload("bool", x)

cel_to_string(x::String) = x
cel_to_string(x::Int64) = string(x)
cel_to_string(x::UInt64) = string(x)
cel_to_string(x::Float64) = _double_to_string(x)
cel_to_string(x::Bool) = string(x)
function cel_to_string(x::CelBytes)
    s = String(copy(x.data))
    isvalid(s) || return CelError(:invalid_argument, "invalid UTF-8 in bytes, cannot convert to string")
    return s
end
cel_to_string(x) = no_overload("string", x)

# Go-style shortest float formatting ("1e+23", not "1.0e23")
function _double_to_string(x::Float64)
    isnan(x) && return "NaN"
    isinf(x) && return x > 0 ? "+Inf" : "-Inf"
    s = string(x)
    if endswith(s, ".0")
        return s[1:end-2]
    end
    if occursin("e", s)
        # Julia: "1.0e23" / "1.0e-5"; Go: "1e+23" / "1e-05"
        m, e = split(s, "e")
        endswith(m, ".0") && (m = m[1:end-2])
        expn = parse(Int, e)
        return string(m, "e", expn < 0 ? "-" : "+", lpad(abs(expn), 2, '0'))
    end
    return s
end

cel_to_bytes(x::CelBytes) = x
cel_to_bytes(x::String) = CelBytes(x)
cel_to_bytes(x) = no_overload("bytes", x)

cel_dyn(x) = x
cel_type(x) = cel_typeof(x)

# ------------------------------------------------------------------
# Helpers called from generated (transpiled) code and the closure backend
# ------------------------------------------------------------------

"Build a CEL list value; propagates element errors."
function _mklist(elems...)
    for e in elems
        e isa CelError && return e
    end
    return Any[elems...]
end

"Build a CEL map value from alternating key/value arguments."
function _mkmap(kvs...)
    m = OrderedDict{Any,Any}()
    for i in 1:2:length(kvs)
        k = kvs[i]
        v = kvs[i+1]
        k isa CelError && return k
        valid_map_key(k) || return CelError(:invalid_argument, "unsupported map key type: $(typename(k))")
        v isa CelError && return v
        map_has(m, k) && return CelError(:invalid_argument, "Failed with repeated key: $(k)")
        m[k] = v
    end
    return m
end

"Non-short-circuit tail of `&&` once neither side is false (error absorption)."
function _and_join(l, r)
    l === true && r === true && return true
    l isa CelError && return l
    r isa CelError && return r
    return no_overload("_&&_", l, r)
end

"Non-short-circuit tail of `||` once neither side is true (error absorption)."
function _or_join(l, r)
    l === false && r === false && return false
    l isa CelError && return l
    r isa CelError && return r
    return no_overload("_||_", l, r)
end

"""
Materialize the items a comprehension iterates: elements of a list or keys
of a map; `(index, element)` / `(key, value)` pairs for two-variable
comprehensions. Returns a CelError for non-aggregate ranges.
"""
function iter_items(range, two::Bool)
    if range isa CelError
        return range
    elseif range isa AbstractVector
        return two ? Any[(Int64(i - 1), v) for (i, v) in enumerate(range)] :
               Any[v for v in range]
    elseif range isa AbstractDict
        return two ? Any[(k, v) for (k, v) in range] : Any[k for k in keys(range)]
    else
        return no_overload("comprehension range", range)
    end
end

"""
Resolve an ident-rooted select path against a bindings dict, mirroring the
closure backend's `compile_resolution`: `cands` are `(qualified_name, k)`
pairs, remaining `parts[k+1:end]` are field selections.
"""
function _resolve_path(vars::AbstractDict, cands, parts, std_fallback)
    for (qname, k) in cands
        haskey(vars, qname) || continue
        v = vars[qname]
        for i in k+1:length(parts)
            v = cel_select(v, parts[i])
            v isa CelError && return v
        end
        return v
    end
    std_fallback === nothing || return std_fallback
    return CelError(:no_such_attribute, "undeclared reference to '$(join(parts, '.'))'")
end

"Internal: step function of the transformMap macro."
function cel_map_insert(m::AbstractDict, k, v)
    valid_map_key(k) || return CelError(:invalid_argument, "unsupported map key type: $(typename(k))")
    map_has(m, k) && return CelError(:invalid_argument, "insert failed: key $(k) already exists")
    out = OrderedDict{Any,Any}(m)
    out[k] = v
    return out
end
cel_map_insert(m, k, v) = no_overload("@map_insert", m, k, v)
