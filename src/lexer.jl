# Lexer for the CEL grammar (https://github.com/google/cel-spec/blob/master/doc/langdef.md#syntax).

@enumx TokenKind begin
    # literals and names
    INT; UINT; FLOAT; STRING; BYTES; IDENT; QIDENT; BOOL; NULL; RESERVED
    # keyword operator
    IN
    # operators and punctuation
    OR; AND; EQ; NE; LE; GE; LT; GT
    PLUS; MINUS; STAR; SLASH; PERCENT; BANG
    LPAREN; RPAREN; LBRACKET; RBRACKET; LBRACE; RBRACE
    DOT; COMMA; COLON; QUESTION
    EOF
end

struct Token
    kind::TokenKind.T
    value::Any     # decoded literal value / identifier name / operator text
    pos::Int       # 1-based byte offset into the source
end

struct LexError <: Exception
    msg::String
    pos::Int
end

const RESERVED_WORDS = Set([
    "as", "break", "const", "continue", "else", "for", "function", "if",
    "import", "let", "loop", "package", "namespace", "return", "var",
    "void", "while",
])

mutable struct Lexer
    src::String
    i::Int          # next byte index
    n::Int
end
Lexer(src::String) = Lexer(src, 1, ncodeunits(src))

@inline peekb(lx::Lexer, off::Int=0) = (j = lx.i + off; j <= lx.n ? codeunit(lx.src, j) : 0x00)
@inline atend(lx::Lexer) = lx.i > lx.n

isdigitb(b::UInt8) = UInt8('0') <= b <= UInt8('9')
ishexb(b::UInt8) = isdigitb(b) || UInt8('a') <= b <= UInt8('f') || UInt8('A') <= b <= UInt8('F')
isidentstartb(b::UInt8) = b == UInt8('_') || UInt8('a') <= b <= UInt8('z') || UInt8('A') <= b <= UInt8('Z')
isidentb(b::UInt8) = isidentstartb(b) || isdigitb(b)

function skip_ws_comments!(lx::Lexer)
    while !atend(lx)
        b = peekb(lx)
        if b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r') || b == UInt8('\f') || b == 0x0b
            lx.i += 1
        elseif b == UInt8('/') && peekb(lx, 1) == UInt8('/')
            while !atend(lx) && peekb(lx) != UInt8('\n')
                lx.i += 1
            end
        else
            break
        end
    end
end

"Tokenize the whole source, appending an :EOF token."
function tokenize(src::String)
    lx = Lexer(src)
    tokens = Token[]
    while true
        skip_ws_comments!(lx)
        if atend(lx)
            push!(tokens, Token(TokenKind.EOF, nothing, lx.i))
            return tokens
        end
        push!(tokens, next_token!(lx))
    end
end

function next_token!(lx::Lexer)
    pos = lx.i
    b = peekb(lx)

    if isdigitb(b) || (b == UInt8('.') && isdigitb(peekb(lx, 1)))
        return lex_number!(lx)
    end

    if isidentstartb(b)
        # Possible string prefix: r/R/b/B combinations directly followed by a quote.
        j = lx.i
        nprefix = 0
        while nprefix < 2
            c = peekb(lx, nprefix)
            (c == UInt8('r') || c == UInt8('R') || c == UInt8('b') || c == UInt8('B')) || break
            nprefix += 1
        end
        if nprefix > 0 && (peekb(lx, nprefix) == UInt8('"') || peekb(lx, nprefix) == UInt8('\''))
            prefix = lowercase(unsafe_substr(lx.src, j, nprefix))
            if nprefix == 1 || (nprefix == 2 && prefix in ("rb", "br"))
                lx.i += nprefix
                raw = 'r' in prefix
                isbytes = 'b' in prefix
                return lex_string!(lx, pos; raw, isbytes)
            end
        end
        return lex_ident!(lx)
    end

    if b == UInt8('"') || b == UInt8('\'')
        return lex_string!(lx, pos; raw=false, isbytes=false)
    end

    if b == UInt8('`')
        # Backtick-quoted identifier (field selection escape syntax).
        lx.i += 1
        start = lx.i
        while !atend(lx) && peekb(lx) != UInt8('`') && peekb(lx) != UInt8('\n') && peekb(lx) != UInt8('\r')
            lx.i += 1
        end
        peekb(lx) == UInt8('`') || throw(LexError("unterminated quoted identifier", pos))
        name = unsafe_substr(lx.src, start, lx.i - start)
        isempty(name) && throw(LexError("empty quoted identifier", pos))
        lx.i += 1
        return Token(TokenKind.QIDENT, name, pos)
    end

    # Operators and punctuation, longest match first.
    two = lx.i + 1 <= lx.n ? unsafe_substr(lx.src, lx.i, 2) : ""
    if haskey(TWO_CHAR_OPS, two)
        lx.i += 2
        return Token(TWO_CHAR_OPS[two], two, pos)
    end
    c = Char(b)
    if haskey(ONE_CHAR_OPS, c)
        lx.i += 1
        return Token(ONE_CHAR_OPS[c], string(c), pos)
    end
    throw(LexError("unexpected character $(repr(Char(b)))", pos))
end

# substring by byte offset/length (all callers stay within ASCII runs)
unsafe_substr(s::String, i::Int, len::Int) = String(codeunits(s)[i:i+len-1])

function lex_ident!(lx::Lexer)
    pos = lx.i
    while !atend(lx) && isidentb(peekb(lx))
        lx.i += 1
    end
    name = unsafe_substr(lx.src, pos, lx.i - pos)
    name == "true" && return Token(TokenKind.BOOL, true, pos)
    name == "false" && return Token(TokenKind.BOOL, false, pos)
    name == "null" && return Token(TokenKind.NULL, nothing, pos)
    name == "in" && return Token(TokenKind.IN, "in", pos)
    name in RESERVED_WORDS && return Token(TokenKind.RESERVED, name, pos)
    return Token(TokenKind.IDENT, name, pos)
end

function lex_number!(lx::Lexer)
    pos = lx.i
    if peekb(lx) == UInt8('0') && (peekb(lx, 1) == UInt8('x') || peekb(lx, 1) == UInt8('X'))
        lx.i += 2
        start = lx.i
        while !atend(lx) && ishexb(peekb(lx))
            lx.i += 1
        end
        lx.i == start && throw(LexError("malformed hex literal", pos))
        digits = unsafe_substr(lx.src, start, lx.i - start)
        mag = parse_magnitude(digits, 16, pos)
        if peekb(lx) == UInt8('u') || peekb(lx) == UInt8('U')
            lx.i += 1
            mag <= typemax(UInt64) || throw(LexError("uint literal out of range", pos))
            return Token(TokenKind.UINT, UInt64(mag), pos)
        end
        # Magnitude token; sign folding (and MinInt) handled in the parser.
        return Token(TokenKind.INT, mag, pos)
    end

    isfloat = false
    while !atend(lx) && isdigitb(peekb(lx))
        lx.i += 1
    end
    if peekb(lx) == UInt8('.') && isdigitb(peekb(lx, 1))
        isfloat = true
        lx.i += 1
        while !atend(lx) && isdigitb(peekb(lx))
            lx.i += 1
        end
    end
    if (peekb(lx) == UInt8('e') || peekb(lx) == UInt8('E'))
        j = 1
        if peekb(lx, j) == UInt8('+') || peekb(lx, j) == UInt8('-')
            j += 1
        end
        if isdigitb(peekb(lx, j))
            isfloat = true
            lx.i += j + 1
            while !atend(lx) && isdigitb(peekb(lx))
                lx.i += 1
            end
        end
    end
    text = unsafe_substr(lx.src, pos, lx.i - pos)
    if isfloat
        v = tryparse(Float64, text)
        # Julia rejects literals that underflow to zero (e.g. 1e-324);
        # round via BigFloat like other CEL implementations do.
        v === nothing && (v = Float64(parse(BigFloat, text)))
        return Token(TokenKind.FLOAT, v, pos)
    end
    if peekb(lx) == UInt8('u') || peekb(lx) == UInt8('U')
        lx.i += 1
        mag = parse_magnitude(text, 10, pos)
        mag <= typemax(UInt64) || throw(LexError("uint literal out of range", pos))
        return Token(TokenKind.UINT, UInt64(mag), pos)
    end
    return Token(TokenKind.INT, parse_magnitude(text, 10, pos), pos)  # magnitude; parser folds sign
end

"Parse an integer-literal magnitude, turning overflow into LexError instead of OverflowError."
function parse_magnitude(digits::String, base::Int, pos::Int)
    v = tryparse(UInt128, digits; base)
    v === nothing && throw(LexError("int literal out of range", pos))
    return v
end

function lex_string!(lx::Lexer, pos::Int; raw::Bool, isbytes::Bool)
    q = peekb(lx)
    triple = peekb(lx, 1) == q && peekb(lx, 2) == q
    lx.i += triple ? 3 : 1
    out = UInt8[]
    while true
        atend(lx) && throw(LexError("unterminated string literal", pos))
        b = peekb(lx)
        if b == q
            if triple
                if peekb(lx, 1) == q && peekb(lx, 2) == q
                    lx.i += 3
                    break
                end
                push!(out, b); lx.i += 1
            else
                lx.i += 1
                break
            end
        elseif b == UInt8('\\') && !raw
            lex_escape!(lx, out, isbytes, pos)
        elseif (b == UInt8('\n') || b == UInt8('\r')) && !triple
            throw(LexError("newline in single-quoted string", pos))
        else
            push!(out, b)
            lx.i += 1
        end
    end
    if isbytes
        return Token(TokenKind.BYTES, CelBytes(out), pos)
    else
        s = String(out)
        isvalid(s) || throw(LexError("invalid UTF-8 in string literal", pos))
        return Token(TokenKind.STRING, s, pos)
    end
end

function lex_escape!(lx::Lexer, out::Vector{UInt8}, isbytes::Bool, spos::Int)
    lx.i += 1  # consume backslash
    atend(lx) && throw(LexError("unterminated escape sequence", spos))
    b = peekb(lx)
    simple = b == UInt8('a') ? 0x07 :
             b == UInt8('b') ? 0x08 :
             b == UInt8('f') ? 0x0c :
             b == UInt8('n') ? 0x0a :
             b == UInt8('r') ? 0x0d :
             b == UInt8('t') ? 0x09 :
             b == UInt8('v') ? 0x0b :
             b == UInt8('\\') ? UInt8('\\') :
             b == UInt8('\'') ? UInt8('\'') :
             b == UInt8('"') ? UInt8('"') :
             b == UInt8('`') ? UInt8('`') :
             b == UInt8('?') ? UInt8('?') : nothing
    if simple !== nothing
        push!(out, simple)
        lx.i += 1
        return
    end
    if b == UInt8('x') || b == UInt8('X')
        lx.i += 1
        v = read_hex!(lx, 2, spos)
        emit_escape_value!(out, v, isbytes, spos)
    elseif b == UInt8('u')
        isbytes && throw(LexError("\\u escape not allowed in bytes literal", spos))
        lx.i += 1
        v = read_hex!(lx, 4, spos)
        emit_codepoint!(out, v, spos)
    elseif b == UInt8('U')
        isbytes && throw(LexError("\\U escape not allowed in bytes literal", spos))
        lx.i += 1
        v = read_hex!(lx, 8, spos)
        emit_codepoint!(out, v, spos)
    elseif UInt8('0') <= b <= UInt8('3')
        v = 0
        for _ in 1:3
            c = peekb(lx)
            UInt8('0') <= c <= UInt8('7') || throw(LexError("malformed octal escape", spos))
            v = v * 8 + (c - UInt8('0'))
            lx.i += 1
        end
        emit_escape_value!(out, v, isbytes, spos)
    else
        throw(LexError("invalid escape sequence \\$(Char(b))", spos))
    end
end

function read_hex!(lx::Lexer, ndigits::Int, spos::Int)
    v = 0
    for _ in 1:ndigits
        c = peekb(lx)
        ishexb(c) || throw(LexError("malformed hex escape", spos))
        v = v * 16 + (isdigitb(c) ? c - UInt8('0') :
                      UInt8('a') <= c <= UInt8('f') ? c - UInt8('a') + 10 : c - UInt8('A') + 10)
        lx.i += 1
    end
    return v
end

emit_escape_value!(out::Vector{UInt8}, v::Int, isbytes::Bool, spos::Int) =
    isbytes ? push!(out, UInt8(v)) : emit_codepoint!(out, v, spos)

function emit_codepoint!(out::Vector{UInt8}, v::Int, spos::Int)
    (0 <= v <= 0x10FFFF && !(0xD800 <= v <= 0xDFFF)) ||
        throw(LexError("invalid code point in escape", spos))
    append!(out, codeunits(string(Char(v))))
end

const TWO_CHAR_OPS = Dict(
    "||" => TokenKind.OR, "&&" => TokenKind.AND, "==" => TokenKind.EQ,
    "!=" => TokenKind.NE, "<=" => TokenKind.LE, ">=" => TokenKind.GE,
)
const ONE_CHAR_OPS = Dict(
    '(' => TokenKind.LPAREN, ')' => TokenKind.RPAREN,
    '[' => TokenKind.LBRACKET, ']' => TokenKind.RBRACKET,
    '{' => TokenKind.LBRACE, '}' => TokenKind.RBRACE,
    '.' => TokenKind.DOT, ',' => TokenKind.COMMA, ':' => TokenKind.COLON,
    '?' => TokenKind.QUESTION, '+' => TokenKind.PLUS, '-' => TokenKind.MINUS,
    '*' => TokenKind.STAR, '/' => TokenKind.SLASH, '%' => TokenKind.PERCENT,
    '!' => TokenKind.BANG, '<' => TokenKind.LT, '>' => TokenKind.GT,
)
