# Timestamp/duration semantics (cel-spec "Timestamps and durations").
#
# CelTimestamp/CelDuration are (seconds, nanos) pairs mirroring the proto
# WKTs; Dates.DateTime is only used for civil-time math (its ms precision
# doesn't matter there — nanos are carried separately).

# Valid CEL timestamp range: 0001-01-01T00:00:00Z .. 9999-12-31T23:59:59Z
const TS_MIN_SECONDS = Int64(-62135596800)
const TS_MAX_SECONDS = Int64(253402300799)
# CEL durations are Go time.Duration: int64 NANOSECONDS (~±292 years),
# narrower than the proto Duration WKT range.
const DUR_MAX_SECONDS = div(typemax(Int64), 1_000_000_000)

const ERR_TS_RANGE = CelError(:overflow, "timestamp out of range")
const ERR_DUR_RANGE = CelError(:overflow, "duration out of range")

const NANOS = Int128(1_000_000_000)

total_nanos(x::CelTimestamp) = Int128(x.seconds) * NANOS + x.nanos
total_nanos(x::CelDuration) = Int128(x.seconds) * NANOS + x.nanos

"Timestamp from total nanos since epoch; nanos always count forward."
function make_timestamp(total::Int128)
    s = fld(total, NANOS)
    ns = total - s * NANOS
    (TS_MIN_SECONDS <= s <= TS_MAX_SECONDS) || return ERR_TS_RANGE
    return CelTimestamp(Int64(s), Int32(ns))
end

"Duration from total nanos; seconds and nanos share the sign."
function make_duration(total::Int128)
    (typemin(Int64) <= total <= typemax(Int64)) || return ERR_DUR_RANGE
    s = div(total, NANOS)   # truncated: same sign
    ns = rem(total, NANOS)
    return CelDuration(Int64(s), Int32(ns))
end

# ------------------------------------------------------------------
# Arithmetic, comparison
# ------------------------------------------------------------------

cel_add(x::CelTimestamp, y::CelDuration) = make_timestamp(total_nanos(x) + total_nanos(y))
cel_add(x::CelDuration, y::CelTimestamp) = make_timestamp(total_nanos(x) + total_nanos(y))
cel_add(x::CelDuration, y::CelDuration) = make_duration(total_nanos(x) + total_nanos(y))
cel_sub(x::CelTimestamp, y::CelDuration) = make_timestamp(total_nanos(x) - total_nanos(y))
cel_sub(x::CelTimestamp, y::CelTimestamp) = make_duration(total_nanos(x) - total_nanos(y))
cel_sub(x::CelDuration, y::CelDuration) = make_duration(total_nanos(x) - total_nanos(y))

for f in (:cel_lt, :cel_le)
    op = f == :cel_lt ? :(<) : :(<=)
    @eval begin
        $f(x::CelTimestamp, y::CelTimestamp) = $op(total_nanos(x), total_nanos(y))
        $f(x::CelDuration, y::CelDuration) = $op(total_nanos(x), total_nanos(y))
    end
end

cel_eq(x::CelTimestamp, y::CelTimestamp) = x == y
cel_eq(x::CelDuration, y::CelDuration) = x == y

# ------------------------------------------------------------------
# timestamp() / duration() conversions
# ------------------------------------------------------------------

cel_to_timestamp(x::CelTimestamp) = x
function cel_to_timestamp(x::Int64)
    (TS_MIN_SECONDS <= x <= TS_MAX_SECONDS) || return ERR_TS_RANGE
    return CelTimestamp(x, Int32(0))
end
cel_to_timestamp(x) = no_overload("timestamp", x)

const RFC3339_RE =
    r"^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"

function cel_to_timestamp(s::String)
    m = match(RFC3339_RE, s)
    m === nothing && return CelError(:invalid_argument, "invalid timestamp: $(repr(s))")
    y, mo, d, h, mi, sec = (parse(Int, m.captures[i]) for i in 1:6)
    (1 <= mo <= 12 && 1 <= d <= Dates.daysinmonth(y, mo) && h <= 23 && mi <= 59 && sec <= 59) ||
        return CelError(:invalid_argument, "invalid timestamp: $(repr(s))")
    frac = m.captures[7]
    ns = 0
    if frac !== nothing
        digits = rpad(frac[2:min(end, 10)], 9, '0')
        ns = parse(Int, digits)
    end
    offset = 0
    tz = m.captures[8]
    if !(tz in ("Z", "z"))
        sign = tz[1] == '-' ? -1 : 1
        offset = sign * (parse(Int, tz[2:3]) * 3600 + parse(Int, tz[5:6]) * 60)
    end
    epoch = round(Int64, Dates.datetime2unix(Dates.DateTime(y, mo, d, h, mi, sec))) - offset
    (TS_MIN_SECONDS <= epoch <= TS_MAX_SECONDS) || return ERR_TS_RANGE
    return CelTimestamp(epoch, Int32(ns))
end

cel_to_duration(x::CelDuration) = x
function cel_to_duration(x::Int64)
    abs(x) <= DUR_MAX_SECONDS || return ERR_DUR_RANGE
    return CelDuration(x, Int32(0))
end
cel_to_duration(x) = no_overload("duration", x)

# Go duration syntax: [-+]? (number unit)+ with units h, m, s, ms, us/µs, ns
function cel_to_duration(s::String)
    str = s
    isempty(str) && return CelError(:invalid_argument, "invalid duration: $(repr(s))")
    neg = false
    if str[1] == '-' || str[1] == '+'
        neg = str[1] == '-'
        str = str[2:end]
    end
    str == "0" && return CelDuration(0, 0)
    total = Int128(0)
    i = firstindex(str)
    matched = false
    while i <= lastindex(str)
        m = match(r"^(\d+)(\.\d*)?(h|m|s|ms|us|µs|ns)", str[i:end])
        m === nothing && return CelError(:invalid_argument, "invalid duration: $(repr(s))")
        intpart = parse(Int128, m.captures[1])
        unit = m.captures[3]
        unit_ns = unit == "h" ? Int128(3_600_000_000_000) :
                  unit == "m" ? Int128(60_000_000_000) :
                  unit == "s" ? Int128(1_000_000_000) :
                  unit == "ms" ? Int128(1_000_000) :
                  unit == "ns" ? Int128(1) : Int128(1_000)  # us/µs
        total += intpart * unit_ns
        if m.captures[2] !== nothing && length(m.captures[2]) > 1
            fracstr = m.captures[2][2:end]
            total += round(Int128, parse(Float64, "0." * fracstr) * unit_ns)
        end
        i += ncodeunits(m.match)
        matched = true
    end
    matched || return CelError(:invalid_argument, "invalid duration: $(repr(s))")
    return make_duration(neg ? -total : total)
end

function cel_to_string(x::CelDuration)
    # CEL formats durations as (possibly fractional) seconds
    ns = abs(total_nanos(x))
    sign = total_nanos(x) < 0 ? "-" : ""
    whole = div(ns, NANOS)
    frac = rem(ns, NANOS)
    frac == 0 && return "$(sign)$(whole)s"
    fracstr = rstrip(lpad(string(frac), 9, '0'), '0')
    return "$(sign)$(whole).$(fracstr)s"
end

function cel_to_string(x::CelTimestamp)
    dt = Dates.unix2datetime(x.seconds)
    base = Dates.format(dt, dateformat"yyyy-mm-dd\THH:MM:SS")
    if x.nanos == 0
        return base * "Z"
    end
    fracstr = rstrip(lpad(string(x.nanos), 9, '0'), '0')
    return base * "." * fracstr * "Z"
end

# ------------------------------------------------------------------
# Accessors (getFullYear, getHours, ... with optional timezone)
# ------------------------------------------------------------------

"""
Provider hook for IANA timezone names: a function
`(name::String, epoch_seconds::Int64) -> Union{Int64,Nothing}` returning the
UTC offset in seconds at that instant. Installed by the TimeZones.jl package
extension; the core only resolves numeric offsets like "+11:00" and "UTC".
"""
const TZ_PROVIDER = Ref{Any}(nothing)

function tz_offset(tz::String, epoch_s::Int64)
    (tz == "" || tz == "UTC" || tz == "Z") && return Int64(0)
    m = match(r"^([+-])(\d{1,2}):(\d{2})$", tz)
    if m !== nothing
        sign = m.captures[1] == "-" ? -1 : 1
        return Int64(sign * (parse(Int, m.captures[2]) * 3600 + parse(Int, m.captures[3]) * 60))
    end
    provider = TZ_PROVIDER[]
    if provider !== nothing
        off = provider(tz, epoch_s)
        off isa Int64 && return off
    end
    return CelError(:invalid_argument,
        provider === nothing ?
        "IANA timezone names require the TimeZones package (load `using TimeZones`): $(repr(tz))" :
        "unknown timezone: $(repr(tz))")
end

function _civil(ts::CelTimestamp, tz::String)
    off = tz_offset(tz, ts.seconds)
    off isa CelError && return off
    return Dates.unix2datetime(ts.seconds + off)
end

for (fname, expr) in (
    ("getFullYear", :(Int64(Dates.year(dt)))),
    ("getMonth", :(Int64(Dates.month(dt) - 1))),          # 0-based
    ("getDayOfYear", :(Int64(Dates.dayofyear(dt) - 1))),  # 0-based
    ("getDayOfMonth", :(Int64(Dates.day(dt) - 1))),       # 0-based
    ("getDate", :(Int64(Dates.day(dt)))),                 # 1-based
    ("getDayOfWeek", :(Int64(mod(Dates.dayofweek(dt), 7)))),  # 0 = Sunday
    ("getHours", :(Int64(Dates.hour(dt)))),
    ("getMinutes", :(Int64(Dates.minute(dt)))),
    ("getSeconds", :(Int64(Dates.second(dt)))),
)
    f = Symbol("cel_" * lowercase(replace(fname, r"([A-Z])" => s"_\1")))
    @eval begin
        function $f(ts::CelTimestamp, tz::String)
            dt = _civil(ts, tz)
            dt isa CelError && return dt
            return $expr
        end
        $f(ts::CelTimestamp) = $f(ts, "")
        $f(x...) = no_overload($fname, x...)
    end
end

# getMilliseconds comes from the nanos field, not civil time
function cel_get_milliseconds(ts::CelTimestamp, tz::String)
    off = tz_offset(tz, ts.seconds)
    off isa CelError && return off
    return Int64(div(ts.nanos, 1_000_000))
end
cel_get_milliseconds(ts::CelTimestamp) = Int64(div(ts.nanos, 1_000_000))
cel_get_milliseconds(x...) = no_overload("getMilliseconds", x...)

# Duration accessors: whole units of the total duration
cel_get_hours(d::CelDuration) = div(d.seconds, 3600)
cel_get_minutes(d::CelDuration) = div(d.seconds, 60)
cel_get_seconds(d::CelDuration) = d.seconds
cel_get_milliseconds(d::CelDuration) = Int64(div(total_nanos(d), 1_000_000) - Int128(d.seconds) * 1000)
