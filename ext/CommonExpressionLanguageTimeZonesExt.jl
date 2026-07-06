# Provides IANA timezone name resolution for CEL timestamp accessors
# (e.g. `ts.getHours('America/Los_Angeles')`) via TimeZones.jl.
module CommonExpressionLanguageTimeZonesExt

using CommonExpressionLanguage: CommonExpressionLanguage
using TimeZones
using Dates

function iana_offset(name::String, epoch_seconds::Int64)
    tz = try
        TimeZone(name, TimeZones.Class(:ALL))  # include legacy names like US/Central
    catch
        return nothing
    end
    dt = Dates.unix2datetime(epoch_seconds)
    zdt = ZonedDateTime(dt, tz; from_utc=true)
    off = zdt.zone.offset
    return Int64(Dates.value(off.std) + Dates.value(off.dst))
end

function __init__()
    CommonExpressionLanguage.TZ_PROVIDER[] = iana_offset
end

end
