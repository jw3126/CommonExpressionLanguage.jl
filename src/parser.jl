# Recursive-descent parser for the CEL grammar, with parse-time macro
# expansion (has/all/exists/exists_one/map/filter) into comprehension/select
# nodes, following cel-go.

struct ParseError <: Exception
    msg::String
    pos::Int
end

mutable struct Parser
    tokens::Vector{Token}
    pos::Int
    source::String
    next_id::Int64
    positions::Dict{Int64,Int}
    depth::Int
end

const MAX_PARSE_DEPTH = 250

function Parser(src::String)
    Parser(tokenize(src), 1, src, 1, Dict{Int64,Int}(), 0)
end

@inline peek(p::Parser) = p.tokens[p.pos]
@inline peekkind(p::Parser) = p.tokens[p.pos].kind
@inline function advance!(p::Parser)
    t = p.tokens[p.pos]
    p.pos = min(p.pos + 1, length(p.tokens))
    return t
end

function expect!(p::Parser, kind::TokenKind.T)
    t = peek(p)
    t.kind == kind || throw(ParseError("expected $(kind), found $(t.kind)", t.pos))
    return advance!(p)
end

accept!(p::Parser, kind::TokenKind.T) = peekkind(p) == kind ? (advance!(p); true) : false

function newid!(p::Parser, pos::Int)
    id = p.next_id
    p.next_id += 1
    p.positions[id] = pos
    return id
end

"""
    parse_cel(source) -> ParsedExpr

Parse a CEL expression. Throws `ParseError` or `LexError` on invalid syntax.
"""
function parse_cel(source::AbstractString)
    src = String(source)
    p = Parser(src)
    e = parse_expr!(p)
    t = peek(p)
    t.kind == TokenKind.EOF || throw(ParseError("unexpected token $(t.kind) after expression", t.pos))
    return ParsedExpr(e, src, p.positions)
end

function checkdepth(p::Parser)
    p.depth > MAX_PARSE_DEPTH && throw(ParseError("expression recursion depth exceeds $(MAX_PARSE_DEPTH)", peek(p).pos))
end

# Expr = ConditionalOr ["?" ConditionalOr ":" Expr]
function parse_expr!(p::Parser)
    p.depth += 1
    checkdepth(p)
    cond = parse_or!(p)
    result = if peekkind(p) == TokenKind.QUESTION
        qpos = advance!(p).pos
        tval = parse_or!(p)
        expect!(p, TokenKind.COLON)
        fval = parse_expr!(p)
        CallExpr(newid!(p, qpos), nothing, "_?_:_", [cond, tval, fval])
    else
        cond
    end
    p.depth -= 1
    return result
end

function parse_or!(p::Parser)
    e = parse_and!(p)
    while peekkind(p) == TokenKind.OR
        opos = advance!(p).pos
        rhs = parse_and!(p)
        e = CallExpr(newid!(p, opos), nothing, "_||_", [e, rhs])
    end
    return e
end

function parse_and!(p::Parser)
    e = parse_relation!(p)
    while peekkind(p) == TokenKind.AND
        opos = advance!(p).pos
        rhs = parse_relation!(p)
        e = CallExpr(newid!(p, opos), nothing, "_&&_", [e, rhs])
    end
    return e
end

const RELOPS = Dict(
    TokenKind.LT => "_<_", TokenKind.LE => "_<=_", TokenKind.GT => "_>_",
    TokenKind.GE => "_>=_", TokenKind.EQ => "_==_", TokenKind.NE => "_!=_",
    TokenKind.IN => "@in",
)

function parse_relation!(p::Parser)
    e = parse_addition!(p)
    while haskey(RELOPS, peekkind(p))
        t = advance!(p)
        rhs = parse_addition!(p)
        e = CallExpr(newid!(p, t.pos), nothing, RELOPS[t.kind], [e, rhs])
    end
    return e
end

function parse_addition!(p::Parser)
    e = parse_multiplication!(p)
    while peekkind(p) == TokenKind.PLUS || peekkind(p) == TokenKind.MINUS
        t = advance!(p)
        rhs = parse_multiplication!(p)
        e = CallExpr(newid!(p, t.pos), nothing, t.kind == TokenKind.PLUS ? "_+_" : "_-_", [e, rhs])
    end
    return e
end

function parse_multiplication!(p::Parser)
    e = parse_unary!(p)
    while peekkind(p) in (TokenKind.STAR, TokenKind.SLASH, TokenKind.PERCENT)
        t = advance!(p)
        rhs = parse_unary!(p)
        fname = t.kind == TokenKind.STAR ? "_*_" : t.kind == TokenKind.SLASH ? "_/_" : "_%_"
        e = CallExpr(newid!(p, t.pos), nothing, fname, [e, rhs])
    end
    return e
end

# Unary = Member | "!" {"!"} Member | "-" {"-"} Member
function parse_unary!(p::Parser)
    k = peekkind(p)
    if k == TokenKind.BANG
        pos = peek(p).pos
        count = 0
        while peekkind(p) == TokenKind.BANG
            advance!(p)
            count += 1
        end
        e = parse_member!(p)
        return isodd(count) ? CallExpr(newid!(p, pos), nothing, "!_", [e]) : e
    elseif k == TokenKind.MINUS
        pos = peek(p).pos
        count = 0
        while peekkind(p) == TokenKind.MINUS
            advance!(p)
            count += 1
        end
        # MinInt: magnitude 2^63 only parses under an odd number of minus
        # signs and with no postfix ops; handle before parse_primary!'s
        # range check rejects it.
        t = peek(p)
        if isodd(count) && t.kind == TokenKind.INT && t.value::UInt128 == UInt128(1) << 63 &&
           p.tokens[p.pos+1].kind ∉ (TokenKind.DOT, TokenKind.LBRACKET)
            advance!(p)
            return ConstExpr(newid!(p, t.pos), typemin(Int64))
        end
        # Fold sign only into a literal DIRECTLY following the minus signs
        # (cel-go does not fold through parentheses: -(-MinInt) must overflow
        # at runtime).
        direct_literal = t.kind == TokenKind.INT || t.kind == TokenKind.FLOAT
        e = parse_member!(p)
        isodd(count) || return e
        if direct_literal && e isa ConstExpr
            e.value isa Int64 && return ConstExpr(e.id, -e.value)
            e.value isa Float64 && return ConstExpr(e.id, -e.value)
        end
        return CallExpr(newid!(p, pos), nothing, "-_", [e])
    end
    return parse_member!(p)
end

# Member = Primary | Member "." IDENT ["(" [ExprList] ")"] | Member "[" Expr "]"
function parse_member!(p::Parser)
    p.depth += 1
    checkdepth(p)
    e = parse_primary!(p)
    while true
        k = peekkind(p)
        if k == TokenKind.DOT
            dotpos = advance!(p).pos
            field = expect_field_name!(p)
            if peekkind(p) == TokenKind.LPAREN
                advance!(p)
                args = parse_exprlist!(p, TokenKind.RPAREN)
                expect!(p, TokenKind.RPAREN)
                e = expand_receiver_macro(p, dotpos, e, field, args)
            else
                e = SelectExpr(newid!(p, dotpos), e, field, false)
            end
        elseif k == TokenKind.LBRACKET
            bpos = advance!(p).pos
            idx = parse_expr!(p)
            expect!(p, TokenKind.RBRACKET)
            e = CallExpr(newid!(p, bpos), nothing, "_[_]", [e, idx])
        else
            break
        end
    end
    p.depth -= 1
    return e
end

# Field selectors and receiver function names admit reserved words and
# backtick-quoted identifiers (only language keywords true/false/null/in stay
# excluded), per cel-spec.
function expect_field_name!(p::Parser)
    t = peek(p)
    if t.kind == TokenKind.IDENT || t.kind == TokenKind.RESERVED || t.kind == TokenKind.QIDENT
        advance!(p)
        return t.value::String
    end
    throw(ParseError("expected field name, found $(t.kind)", t.pos))
end

function parse_exprlist!(p::Parser, terminator::TokenKind.T)
    args = CelExpr[]
    peekkind(p) == terminator && return args
    push!(args, parse_expr!(p))
    while accept!(p, TokenKind.COMMA)
        peekkind(p) == terminator && break  # trailing comma
        push!(args, parse_expr!(p))
    end
    return args
end

function parse_primary!(p::Parser)
    t = peek(p)
    k = t.kind
    if k == TokenKind.INT
        advance!(p)
        mag = t.value::UInt128
        mag <= UInt128(typemax(Int64)) || throw(ParseError("int literal out of range", t.pos))
        return ConstExpr(newid!(p, t.pos), Int64(mag))
    elseif k in (TokenKind.UINT, TokenKind.FLOAT, TokenKind.STRING, TokenKind.BYTES, TokenKind.BOOL, TokenKind.NULL)
        advance!(p)
        return ConstExpr(newid!(p, t.pos), t.value)
    elseif k == TokenKind.LPAREN
        advance!(p)
        e = parse_expr!(p)
        expect!(p, TokenKind.RPAREN)
        return e
    elseif k == TokenKind.LBRACKET
        advance!(p)
        elems = parse_exprlist!(p, TokenKind.RBRACKET)
        expect!(p, TokenKind.RBRACKET)
        return ListExpr(newid!(p, t.pos), elems)
    elseif k == TokenKind.LBRACE
        advance!(p)
        entries = MapEntry[]
        while peekkind(p) != TokenKind.RBRACE
            kpos = peek(p).pos
            key = parse_expr!(p)
            expect!(p, TokenKind.COLON)
            val = parse_expr!(p)
            push!(entries, MapEntry(newid!(p, kpos), key, val))
            accept!(p, TokenKind.COMMA) || break
        end
        expect!(p, TokenKind.RBRACE)
        return MapExpr(newid!(p, t.pos), entries)
    elseif k == TokenKind.IDENT || k == TokenKind.DOT
        return parse_ident_or_call!(p)
    elseif k == TokenKind.RESERVED
        throw(ParseError("reserved word '$(t.value)' cannot be used as an identifier", t.pos))
    else
        throw(ParseError("unexpected token $(k)", t.pos))
    end
end

# ["."] IDENT ["(" [ExprList] ")"]  |  ["."] IDENT {"." IDENT} "{" [FieldInits] "}"
function parse_ident_or_call!(p::Parser)
    start = peek(p).pos
    absolute = accept!(p, TokenKind.DOT)
    t = expect!(p, TokenKind.IDENT)
    name = (absolute ? "." : "") * (t.value::String)

    if peekkind(p) == TokenKind.LPAREN
        advance!(p)
        args = parse_exprlist!(p, TokenKind.RPAREN)
        expect!(p, TokenKind.RPAREN)
        return expand_global_macro(p, start, name, args)
    end

    # Qualified name: keep consuming ".IDENT" only while it can be part of a
    # message-construction name (lookahead for `{`); otherwise leave selection
    # to parse_member!.
    if message_construction_ahead(p)
        parts = [name]
        while peekkind(p) == TokenKind.DOT
            advance!(p)
            ti = expect!(p, TokenKind.IDENT)
            push!(parts, ti.value::String)
            peekkind(p) == TokenKind.LBRACE && break
        end
        expect!(p, TokenKind.LBRACE)
        entries = FieldEntry[]
        while peekkind(p) != TokenKind.RBRACE
            fpos = peek(p).pos
            fieldname = expect_field_name!(p)
            expect!(p, TokenKind.COLON)
            val = parse_expr!(p)
            push!(entries, FieldEntry(newid!(p, fpos), fieldname, val))
            accept!(p, TokenKind.COMMA) || break
        end
        expect!(p, TokenKind.RBRACE)
        return StructExpr(newid!(p, start), join(parts, "."), entries)
    end

    return IdentExpr(newid!(p, start), name)
end

# Lookahead: from the current position, does `{"." IDENT} "{"` follow?
function message_construction_ahead(p::Parser)
    i = p.pos
    toks = p.tokens
    while i <= length(toks) && toks[i].kind == TokenKind.DOT
        i + 1 <= length(toks) && toks[i+1].kind == TokenKind.IDENT || return false
        i += 2
    end
    return i <= length(toks) && toks[i].kind == TokenKind.LBRACE
end

# ------------------------------------------------------------------
# Macro expansion (cel-spec "Macros"; expansions match cel-go)
# ------------------------------------------------------------------

function expand_global_macro(p::Parser, pos::Int, name::String, args::Vector{CelExpr})
    if name == "has"
        length(args) == 1 || throw(ParseError("has() requires exactly one argument", pos))
        sel = args[1]
        sel isa SelectExpr && !sel.test_only ||
            throw(ParseError("has() argument must be a field selection", pos))
        return SelectExpr(newid!(p, pos), sel.operand, sel.field, true)
    end
    return CallExpr(newid!(p, pos), nothing, name, args)
end

function macro_var(p::Parser, pos::Int, e::CelExpr, what::String)
    e isa IdentExpr && !startswith(e.name, ".") ||
        throw(ParseError("$(what) of a comprehension macro must be a simple identifier", pos))
    n = e.name
    n == ACCU_VAR && throw(ParseError("comprehension variable must not be '$(ACCU_VAR)'", pos))
    return n
end

function expand_receiver_macro(p::Parser, pos::Int, target::CelExpr, fname::String, args::Vector{CelExpr})
    nid(x) = newid!(p, pos)
    accu() = IdentExpr(nid(0), ACCU_VAR)

    if fname == "all" && length(args) in (2, 3)
        v1 = macro_var(p, pos, args[1], "iteration variable")
        v2 = length(args) == 3 ? macro_var(p, pos, args[2], "iteration variable") : ""
        pred = args[end]
        v2 == v1 && v2 != "" && throw(ParseError("duplicate comprehension variable '$(v1)'", pos))
        return ComprehensionExpr(nid(0), v1, v2, target, ACCU_VAR,
            ConstExpr(nid(0), true),
            CallExpr(nid(0), nothing, "@not_strictly_false", [accu()]),
            CallExpr(nid(0), nothing, "_&&_", [accu(), pred]),
            accu())
    elseif fname == "exists" && length(args) in (2, 3)
        v1 = macro_var(p, pos, args[1], "iteration variable")
        v2 = length(args) == 3 ? macro_var(p, pos, args[2], "iteration variable") : ""
        pred = args[end]
        v2 == v1 && v2 != "" && throw(ParseError("duplicate comprehension variable '$(v1)'", pos))
        return ComprehensionExpr(nid(0), v1, v2, target, ACCU_VAR,
            ConstExpr(nid(0), false),
            CallExpr(nid(0), nothing, "@not_strictly_false",
                [CallExpr(nid(0), nothing, "!_", [accu()])]),
            CallExpr(nid(0), nothing, "_||_", [accu(), pred]),
            accu())
    elseif (fname == "exists_one" || fname == "existsOne") && length(args) in (2, 3)
        v1 = macro_var(p, pos, args[1], "iteration variable")
        v2 = length(args) == 3 ? macro_var(p, pos, args[2], "iteration variable") : ""
        pred = args[end]
        v2 == v1 && v2 != "" && throw(ParseError("duplicate comprehension variable '$(v1)'", pos))
        return ComprehensionExpr(nid(0), v1, v2, target, ACCU_VAR,
            ConstExpr(nid(0), Int64(0)),
            ConstExpr(nid(0), true),
            CallExpr(nid(0), nothing, "_?_:_", [pred,
                CallExpr(nid(0), nothing, "_+_", [accu(), ConstExpr(nid(0), Int64(1))]),
                accu()]),
            CallExpr(nid(0), nothing, "_==_", [accu(), ConstExpr(nid(0), Int64(1))]))
    elseif fname == "map" && length(args) in (2, 3)
        v1 = macro_var(p, pos, args[1], "iteration variable")
        transform = args[end]
        step = CallExpr(nid(0), nothing, "_+_", [accu(), ListExpr(nid(0), [transform])])
        if length(args) == 3
            step = CallExpr(nid(0), nothing, "_?_:_", [args[2], step, accu()])
        end
        return ComprehensionExpr(nid(0), v1, "", target, ACCU_VAR,
            ListExpr(nid(0), CelExpr[]), ConstExpr(nid(0), true), step, accu())
    elseif fname == "transformList" && length(args) in (3, 4)
        v1 = macro_var(p, pos, args[1], "iteration variable")
        v2 = macro_var(p, pos, args[2], "iteration variable")
        v2 == v1 && throw(ParseError("duplicate comprehension variable '$(v1)'", pos))
        transform = args[end]
        step = CallExpr(nid(0), nothing, "_+_", [accu(), ListExpr(nid(0), [transform])])
        if length(args) == 4
            step = CallExpr(nid(0), nothing, "_?_:_", [args[3], step, accu()])
        end
        return ComprehensionExpr(nid(0), v1, v2, target, ACCU_VAR,
            ListExpr(nid(0), CelExpr[]), ConstExpr(nid(0), true), step, accu())
    elseif fname == "transformMap" && length(args) in (3, 4)
        v1 = macro_var(p, pos, args[1], "iteration variable")
        v2 = macro_var(p, pos, args[2], "iteration variable")
        v2 == v1 && throw(ParseError("duplicate comprehension variable '$(v1)'", pos))
        transform = args[end]
        step = CallExpr(nid(0), nothing, "@map_insert",
            [accu(), IdentExpr(nid(0), v1), transform])
        if length(args) == 4
            step = CallExpr(nid(0), nothing, "_?_:_", [args[3], step, accu()])
        end
        return ComprehensionExpr(nid(0), v1, v2, target, ACCU_VAR,
            MapExpr(nid(0), MapEntry[]), ConstExpr(nid(0), true), step, accu())
    elseif fname == "filter" && length(args) == 2
        v1 = macro_var(p, pos, args[1], "iteration variable")
        step = CallExpr(nid(0), nothing, "_+_", [accu(), ListExpr(nid(0), [args[1]])])
        step = CallExpr(nid(0), nothing, "_?_:_", [args[2], step, accu()])
        return ComprehensionExpr(nid(0), v1, "", target, ACCU_VAR,
            ListExpr(nid(0), CelExpr[]), ConstExpr(nid(0), true), step, accu())
    end
    return CallExpr(newid!(p, pos), target, fname, args)
end
