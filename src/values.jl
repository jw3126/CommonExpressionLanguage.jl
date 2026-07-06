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
