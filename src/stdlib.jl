# The CEL standard function table, mapping CEL function names to the Julia
# generic functions in ops.jl. Overload selection is Julia multiple dispatch;
# unmatched signatures fall through to each function's `no_overload` method.
#
# `_&&_`, `_||_`, `_?_:_` and `@not_strictly_false` are special forms handled
# by the backends (short-circuit / error absorption), not table entries.

# Predeclared identifiers: type denotations usable as first-class values,
# e.g. `type(1) == int`.
const STD_IDENTS = Dict{String,Any}(
    "int" => IntType,
    "uint" => UIntType,
    "double" => DoubleType,
    "bool" => BoolType,
    "string" => StringType,
    "bytes" => BytesType,
    "list" => ListType,
    "map" => MapType,
    "null_type" => NullTypeV,
    "type" => TypeType,
    "google.protobuf.Timestamp" => TimestampType,
    "google.protobuf.Duration" => DurationType,
)

const STDLIB = Dict{String,Any}(
    "_+_" => cel_add,
    "_-_" => cel_sub,
    "_*_" => cel_mul,
    "_/_" => cel_div,
    "_%_" => cel_mod,
    "-_" => cel_neg,
    "!_" => cel_not,
    "_==_" => cel_eq,
    "_!=_" => cel_ne,
    "_<_" => cel_lt,
    "_<=_" => cel_le,
    "_>_" => cel_gt,
    "_>=_" => cel_ge,
    "_[_]" => cel_index,
    "@in" => cel_in,
    "size" => cel_size,
    "contains" => cel_contains,
    "startsWith" => cel_starts_with,
    "endsWith" => cel_ends_with,
    "matches" => cel_matches,
    "int" => cel_to_int,
    "uint" => cel_to_uint,
    "double" => cel_to_double,
    "bool" => cel_to_bool,
    "string" => cel_to_string,
    "bytes" => cel_to_bytes,
    "dyn" => cel_dyn,
    "type" => cel_type,
    "@map_insert" => cel_map_insert,
    # timestamps / durations
    "timestamp" => cel_to_timestamp,
    "duration" => cel_to_duration,
    "getFullYear" => cel_get_full_year,
    "getMonth" => cel_get_month,
    "getDayOfYear" => cel_get_day_of_year,
    "getDayOfMonth" => cel_get_day_of_month,
    "getDate" => cel_get_date,
    "getDayOfWeek" => cel_get_day_of_week,
    "getHours" => cel_get_hours,
    "getMinutes" => cel_get_minutes,
    "getSeconds" => cel_get_seconds,
    "getMilliseconds" => cel_get_milliseconds,
)
