# Minimal schema-less textproto reader, just enough for the cel-spec
# conformance files (SimpleTestFile). Interim solution until ProtocGen.jl
# gains textproto support; then this file is deleted and the harness loads
# generated cel.expr messages instead.
#
# Representation: a message is an OrderedDict{String,Vector{Any}} (field name
# => occurrences). Scalar values: Vector{UInt8} for strings/bytes (the caller
# decides the interpretation), String for numbers (schema decides int/float),
# Bool for true/false, Symbol for enum identifiers.

module TextProto

using OrderedCollections: OrderedDict

struct TPToken
    kind::Symbol  # :IDENT,:STRING,:NUMBER,:PUNCT,:EOF
    value::Any
end

function tp_tokenize(src::String)
    toks = TPToken[]
    i = 1
    n = ncodeunits(src)
    cu(j) = j <= n ? codeunit(src, j) : 0x00
    while i <= n
        b = cu(i)
        c = Char(b)
        if c in (' ', '\t', '\n', '\r', ',')
            i += 1
        elseif c == '#'
            while i <= n && cu(i) != UInt8('\n')
                i += 1
            end
        elseif c in ('{', '}', '<', '>', '[', ']', ':', '/')
            push!(toks, TPToken(:PUNCT, c))
            i += 1
        elseif c == '"' || c == '\''
            q = b
            i += 1
            out = UInt8[]
            while true
                i <= n || error("unterminated textproto string")
                b2 = cu(i)
                if b2 == q
                    i += 1
                    break
                elseif b2 == UInt8('\\')
                    i = tp_escape!(out, src, i, n)
                else
                    push!(out, b2)
                    i += 1
                end
            end
            push!(toks, TPToken(:STRING, out))
        elseif isdigit(c) || c == '-' || c == '+' || c == '.'
            if c == '-' && i < n && isletter(src[i+1])
                # -inf / -Infinity / -nan spelled as ident after the sign
                j = i + 1
                while j <= n && isletter(src[j])
                    j += 1
                end
                push!(toks, TPToken(:NUMBER, src[i:j-1]))
                i = j
                continue
            end
            j = i
            while j <= n && (Char(cu(j)) in "0123456789+-.eExXabcdefABCDEF")
                j += 1
            end
            # also covers "-inf": handled below via IDENT since 'inf' letters not in set... include:
            push!(toks, TPToken(:NUMBER, src[i:j-1]))
            i = j
        elseif isletter(c) || c == '_'
            j = i
            while j <= n && (Char(cu(j)) == '_' || isletter(Char(cu(j))) || isdigit(Char(cu(j))))
                j += 1
            end
            word = src[i:j-1]
            if word == "true"
                push!(toks, TPToken(:IDENT, true))
            elseif word == "false"
                push!(toks, TPToken(:IDENT, false))
            else
                push!(toks, TPToken(:IDENT, Symbol(word)))
            end
            i = j
        else
            error("unexpected character in textproto: $(repr(c)) at byte $i")
        end
    end
    push!(toks, TPToken(:EOF, nothing))
    return toks
end

function tp_escape!(out::Vector{UInt8}, src::String, i::Int, n::Int)
    cu(j) = j <= n ? codeunit(src, j) : 0x00
    i += 1  # backslash
    b = cu(i)
    c = Char(b)
    simple = Dict('a' => 0x07, 'b' => 0x08, 'f' => 0x0c, 'n' => 0x0a, 'r' => 0x0d,
        't' => 0x09, 'v' => 0x0b, '\\' => UInt8('\\'), '\'' => UInt8('\''),
        '"' => UInt8('"'), '?' => UInt8('?'), '/' => UInt8('/'))
    if haskey(simple, c)
        push!(out, simple[c])
        return i + 1
    elseif c == 'x' || c == 'X'
        i += 1
        v = 0
        cnt = 0
        while cnt < 2 && i <= n && isxdigit(Char(cu(i)))
            v = v * 16 + parse(Int, Char(cu(i)); base=16)
            i += 1
            cnt += 1
        end
        cnt > 0 || error("bad \\x escape")
        push!(out, UInt8(v))
        return i
    elseif c == 'u'
        i += 1
        v = 0
        for _ in 1:4
            v = v * 16 + parse(Int, Char(cu(i)); base=16)
            i += 1
        end
        append!(out, codeunits(string(Char(v))))
        return i
    elseif c == 'U'
        i += 1
        v = 0
        for _ in 1:8
            v = v * 16 + parse(Int, Char(cu(i)); base=16)
            i += 1
        end
        append!(out, codeunits(string(Char(v))))
        return i
    elseif '0' <= c <= '7'
        v = 0
        cnt = 0
        while cnt < 3 && i <= n && '0' <= Char(cu(i)) <= '7'
            v = v * 8 + (cu(i) - UInt8('0'))
            i += 1
            cnt += 1
        end
        push!(out, UInt8(v))
        return i
    else
        error("bad textproto escape \\$c")
    end
end

mutable struct TPParser
    toks::Vector{TPToken}
    pos::Int
end

tp_peek(p::TPParser) = p.toks[p.pos]
tp_next!(p::TPParser) = (t = p.toks[p.pos]; p.pos += 1; t)

"Parse a whole textproto file into a message dict."
function parse_file(path::AbstractString)
    p = TPParser(tp_tokenize(read(path, String)), 1)
    return parse_fields!(p, :EOF)
end

function parse_fields!(p::TPParser, closer)
    msg = OrderedDict{String,Vector{Any}}()
    while true
        t = tp_peek(p)
        if t.kind == :EOF
            closer == :EOF || error("unexpected EOF in textproto")
            return msg
        end
        if t.kind == :PUNCT && t.value == closer
            tp_next!(p)
            return msg
        end
        if t.kind == :PUNCT && t.value == '['
            # Any/extension field: [type.googleapis.com/pkg.Msg] { ... }
            tp_next!(p)
            io = IOBuffer()
            while !(tp_peek(p).kind == :PUNCT && tp_peek(p).value == ']')
                tok = tp_next!(p)
                tok.kind == :EOF && error("unterminated extension field name")
                print(io, tok.value isa Symbol ? String(tok.value) : string(tok.value))
            end
            tp_next!(p)
            name = "[" * String(take!(io)) * "]"
        else
            t.kind == :IDENT || error("expected field name, got $(t)")
            name = String(t.value::Symbol)
            tp_next!(p)
        end
        t2 = tp_peek(p)
        if t2.kind == :PUNCT && (t2.value == '{' || t2.value == '<')
            tp_next!(p)
            v = parse_fields!(p, t2.value == '{' ? '}' : '>')
            push!(get!(msg, name, Any[]), v)
        elseif t2.kind == :PUNCT && t2.value == ':'
            tp_next!(p)
            t3 = tp_peek(p)
            if t3.kind == :PUNCT && (t3.value == '{' || t3.value == '<')
                tp_next!(p)
                v = parse_fields!(p, t3.value == '{' ? '}' : '>')
                push!(get!(msg, name, Any[]), v)
            elseif t3.kind == :PUNCT && t3.value == '['
                tp_next!(p)
                while !(tp_peek(p).kind == :PUNCT && tp_peek(p).value == ']')
                    tl = tp_peek(p)
                    if tl.kind == :PUNCT && (tl.value == '{' || tl.value == '<')
                        tp_next!(p)
                        push!(get!(msg, name, Any[]), parse_fields!(p, tl.value == '{' ? '}' : '>'))
                    else
                        push!(get!(msg, name, Any[]), parse_scalar!(p))
                    end
                end
                tp_next!(p)
            else
                push!(get!(msg, name, Any[]), parse_scalar!(p))
            end
        else
            error("expected ':' or '{' after field $(name)")
        end
    end
end

function parse_scalar!(p::TPParser)
    t = tp_next!(p)
    if t.kind == :STRING
        out = t.value::Vector{UInt8}
        # adjacent string literals concatenate
        while tp_peek(p).kind == :STRING
            append!(out, tp_next!(p).value::Vector{UInt8})
        end
        return out
    elseif t.kind == :NUMBER
        return t.value::String
    elseif t.kind == :IDENT
        return t.value  # Bool or Symbol (enum value, inf, nan, ...)
    else
        error("expected scalar value, got $(t)")
    end
end

# Accessors for the generic representation
getone(msg, name, default=nothing) =
    haskey(msg, name) && !isempty(msg[name]) ? msg[name][1] : default
getall(msg, name) = get(msg, name, Any[])
asstring(x::Vector{UInt8}) = String(copy(x))
asstring(x::Nothing) = nothing

end # module
