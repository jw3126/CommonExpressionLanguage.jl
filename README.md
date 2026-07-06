# CommonExpressionLanguage

[![Build Status](https://github.com/jw3126/CommonExpressionLanguage.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jw3126/CommonExpressionLanguage.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/jw3126/CommonExpressionLanguage.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jw3126/CommonExpressionLanguage.jl)

A Julia implementation of [CEL, the Common Expression Language](https://github.com/google/cel-spec):
parser, static type checker, and **two evaluation backends** — a closure
compiler for expressions supplied at runtime, and a Julia-source transpiler
for code generators (e.g. emitting [protovalidate](https://github.com/bufbuild/protovalidate)-style
`validate(msg)` functions into ProtocGen.jl-generated code).

Verified against the official cel-spec conformance test suite: all 1835
applicable conformance tests pass on both backends (protobuf-message tests
are pending the ProtocGen.jl integration; CEL extensions like `optionals`
and `math_ext` are not implemented).

## Usage

```julia
using CommonExpressionLanguage
const CEL = CommonExpressionLanguage

# one-shot
evaluate("1 + 2 * 3")                                # 7
evaluate("x.startsWith('h')", vars=Dict("x" => "hi")) # true

# compile once, run many times (closure backend)
prog = compile("size(name) <= 10 && name.matches('^[a-z]+$')")
prog(Dict("name" => "hello"))                        # true
prog(Dict("name" => "Hello!"))                       # false
```

CEL semantics are honored throughout: `int`/`uint` are distinct
overflow-checked types, `1 == 1.0` is true, and evaluation errors are
*values* that short-circuiting operators can absorb:

```julia
evaluate("1/0")                     # CelError(:divide_by_zero, "divide by zero")
evaluate("false && (1/0 > 0)")      # false — && absorbs the error
evaluate("[1,2,3].exists(x, x/0 > 0 || x == 2)")  # true
```

### Static type checking

```julia
env = CheckerEnv(variables = Dict("x" => CEL.INT_T, "name" => CEL.STRING_T))
check(env, "x + 1 > 2")             # CheckedExpr, root type bool
check(env, "x + name")              # throws CheckError: no matching overload
```

### Transpiling to Julia source

`transpile` turns a CEL expression into a plain Julia expression calling
this package's semantics helpers — for code generators that want zero
runtime compilation and full JIT specialization:

```julia
# codegen style: bind CEL variables directly to Julia expressions
ex = transpile("size(this) <= 100";
               varmap=Dict{String,Any}("this" => :(msg.name)), varsdict=nothing)
# splice `ex` into a generated function body:
# function validate(msg::MyMessage); $ex; end

# or get a runnable function definition taking bindings
f = eval(transpile_function("a + b"))
f((a = 1, b = 2))                            # 3 — NamedTuple: lookups
                                             # constant-fold, no dict overhead
f(Dict{String,Any}("a" => 1, "b" => 2))      # 3 — dict also works
```

### Timezones

Timestamp accessors accept numeric UTC offsets out of the box
(`ts.getHours("+02:00")`). IANA names (`ts.getHours("Europe/Berlin")`)
require loading [TimeZones.jl](https://github.com/JuliaTime/TimeZones.jl),
which activates a package extension.

## Conformance & limitations

The vendored [cel-spec conformance suite](test/testdata/README.md) runs in
CI against both backends (`test/conformance.jl`). Current gaps:

- **Protobuf messages**: message construction, field selection on messages,
  enums, and wrapper types await the ProtocGen.jl adapter (`src/adapter.jl`
  defines the hook interface). These tests are auto-skipped and counted.
- **CEL extensions**: `optionals`, `bindings_ext`, `block_ext`, `math_ext`,
  `string_ext`, `encoders_ext` are not implemented.
- `matches()` uses Julia's PCRE2 rather than RE2. PCRE-only constructs that
  RE2 rejects (lookarounds, backreferences, atomic groups) are detected and
  rejected, and compiled patterns are cached; exotic syntax differences
  beyond that may remain. All conformance regex tests pass.
