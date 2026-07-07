# CEL runtime values.
#
# CEL type    Julia representation
# --------    --------------------
# int         Int64
# uint        UInt64
# double      Float64
# bool        Bool
# string      String
# bytes       CelBytes            (wrapper: a bare Vector{UInt8} would be ambiguous with lists)
# null        nothing
# list        Vector (covariant element type; literals build Vector{Any})
# map         OrderedDict{Any,Any}
# timestamp   CelTimestamp        (ns precision; Dates.DateTime only has ms)
# duration    CelDuration
# type        CelType
# error       CelError            (errors are values, absorbed by &&/||/?: per spec)

using OrderedCollections: OrderedDict

struct CelBytes
    data::Vector{UInt8}
end
CelBytes(s::AbstractString) = CelBytes(Vector{UInt8}(codeunits(s)))
Base.:(==)(a::CelBytes, b::CelBytes) = a.data == b.data
Base.hash(a::CelBytes, h::UInt) = hash(a.data, hash(:CelBytes, h))
Base.length(a::CelBytes) = length(a.data)

"""
Timestamp as (seconds, nanos) since Unix epoch, mirroring google.protobuf.Timestamp.
Invariant: 0 <= nanos < 1_000_000_000 (nanos always counts forward from `seconds`).
Valid range per CEL spec: 0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z.
"""
struct CelTimestamp
    seconds::Int64
    nanos::Int32
end

"""
Signed duration as (seconds, nanos), mirroring google.protobuf.Duration.
Invariant: seconds and nanos have the same sign (or are zero); abs(nanos) < 1e9.
Range: approximately ±10_000 years, checked on construction via `make_duration`.
"""
struct CelDuration
    seconds::Int64
    nanos::Int32
end

Base.:(==)(a::CelDuration, b::CelDuration) = a.seconds == b.seconds && a.nanos == b.nanos
Base.hash(a::CelDuration, h::UInt) = hash((a.seconds, a.nanos), hash(:CelDuration, h))
Base.:(==)(a::CelTimestamp, b::CelTimestamp) = a.seconds == b.seconds && a.nanos == b.nanos
Base.hash(a::CelTimestamp, h::UInt) = hash((a.seconds, a.nanos), hash(:CelTimestamp, h))

"""
CEL map value. A plain Julia dict cannot implement CEL key semantics:
`isequal(true, 1)` is true in Julia, but CEL bool keys are distinct from
numeric keys, while int/uint/double keys that are numerically equal are the
SAME key (`{1: 'a'}[1.0] == 'a'`). CelMap stores a normalized
`(class, value)` key internally and keeps the original key for iteration.
"""
struct CelMap <: AbstractDict{Any,Any}
    data::OrderedDict{Any,Pair{Any,Any}}   # normkey => (original key => value)
    CelMap() = new(OrderedDict{Any,Pair{Any,Any}}())
end
function CelMap(pairs)
    m = CelMap()
    for (k, v) in pairs
        m[k] = v
    end
    return m
end

"Normalized map key: a class byte keeps bool/numeric/string keys apart."
function normkey(k)
    k isa Bool && return (0x02, k)
    k isa Int64 && return (0x01, k)
    k isa UInt64 && return (0x01, k <= UInt64(typemax(Int64)) ? Int64(k) : k)
    if k isa Float64
        (isinteger(k) && typemin(Int64) <= k <= typemax(Int64)) && return (0x01, Int64(k))
        return (0x01, k)
    end
    k isa String && return (0x03, k)
    return (0x00, k)
end

Base.length(m::CelMap) = length(m.data)
function Base.iterate(m::CelMap, state...)
    it = iterate(m.data, state...)
    it === nothing && return nothing
    (_, kv), st = it
    return (kv, st)
end
Base.haskey(m::CelMap, k) = haskey(m.data, normkey(k))
function Base.get(m::CelMap, k, default)
    kv = get(m.data, normkey(k), nothing)
    return kv === nothing ? default : kv.second
end
function Base.getindex(m::CelMap, k)
    kv = get(m.data, normkey(k), nothing)
    kv === nothing && throw(KeyError(k))
    return kv.second
end
Base.setindex!(m::CelMap, v, k) = (m.data[normkey(k)] = (k => v); m)

"""
First-class CEL type value, e.g. the result of `type(1)`.

`name` is the canonical runtime type name (`"int"`, `"list"`, `"map"`,
`"null_type"`, `"google.protobuf.Timestamp"`, message names, or `"type"`).
Runtime type values are unparameterized per spec (type(list<int>) == list).
"""
struct CelType
    name::String
end
Base.:(==)(a::CelType, b::CelType) = a.name == b.name
Base.hash(a::CelType, h::UInt) = hash(a.name, hash(:CelType, h))

const IntType = CelType("int")
const UIntType = CelType("uint")
const DoubleType = CelType("double")
const BoolType = CelType("bool")
const StringType = CelType("string")
const BytesType = CelType("bytes")
const ListType = CelType("list")
const MapType = CelType("map")
const NullTypeV = CelType("null_type")
const TypeType = CelType("type")
const TimestampType = CelType("google.protobuf.Timestamp")
const DurationType = CelType("google.protobuf.Duration")

"""
A CEL evaluation error as a value. Propagates through strict operations and
is absorbed by `&&`/`||`/`?:`/comprehension short-circuits per spec.
`kind` is a stable symbol used for conformance matching (e.g. `:divide_by_zero`,
`:no_such_field`, `:overflow`, `:no_matching_overload`, `:invalid_argument`,
`:no_such_key`, `:index_out_of_range`, `:no_such_attribute`).
"""
struct CelError
    kind::Symbol
    msg::String
end

iserror(x) = x isa CelError
iserror(x::CelError) = true

"Runtime CEL type of a value (the `type()` function)."
function cel_typeof(x)
    x isa Int64 && return IntType
    x isa UInt64 && return UIntType
    x isa Float64 && return DoubleType
    x isa Bool && return BoolType
    x isa String && return StringType
    x isa CelBytes && return BytesType
    x isa Nothing && return NullTypeV
    x isa AbstractVector && return ListType
    x isa AbstractDict && return MapType
    x isa CelTimestamp && return TimestampType
    x isa CelDuration && return DurationType
    x isa CelType && return TypeType
    return adapter_typeof(x)
end
