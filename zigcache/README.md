# zigcache

The analyser half of `../purecache/`, ported to `std.zig.Ast`. Same job: for
every top-level fn marked `///cache:pure`, checksum the function plus every
top-level declaration it transitively references, and reject purity violations.

```sh
zig build-exe src/main.zig -femit-bin=zigcache
./zigcache example/calc.zig    # prints checksums
./zigcache example/bad.zig     # exits 1 with 11 violations
```

## What std.zig actually provides

Everything the Go generator uses from `go/ast` + `go/printer` has a
counterpart, and a couple of things Go has no equivalent for:

| need | Go | Zig |
|---|---|---|
| parser | `go/parser.ParseDir` | `std.zig.Ast.parse` |
| canonical printer | `go/printer.Config.Fprint` | `Ast.renderAlloc` (= `zig fmt`) |
| typed decl accessors | struct field access | `fullFnProto`, `fullVarDecl`, `fullCall`, `full.FnProto.iterate` |
| node source extent | `Pos()`/`End()` | `firstToken`/`lastToken`/`getNodeSource` |
| source hashing | — | `std.zig.hashSrc` / `SrcHash` (the compiler's own Blake3) |
| semantic lowering | `go/types` | `std.zig.AstGen` → `std.zig.Zir` |
| **generic AST walker** | **`ast.Inspect`** | **absent** |

## Where Zig came out ahead

**Canonicalisation.** This is the piece the whole scheme rests on: reformatting
or rewording a comment must not invalidate the cache. In Zig it is free —
`//` comments are not tokens, so hashing the token range
`firstToken(node)..lastToken(node)` (skipping `///` doc comments) is
comment- and whitespace-insensitive by construction. Twelve lines, correct
first try.

The Go version needs `printer` output, which re-emits `Doc`/`Comment` fields
and reproduces blank lines from node positions. Getting it right meant clearing
comment fields on six node types and post-stripping blank lines — and the first
attempt was wrong. The test caught it, but Zig's formulation cannot be wrong in
that way.

**Size.** 398 lines vs 685 for the equivalent Go analyser.

## Where Zig came out behind

**No generic AST walker.** `std.zig.Ast` is struct-of-arrays with tag-specific
data layout and no `ast.Inspect` equivalent, so structural analysis means
either hand-written dispatch over ~150 node tags or falling back to token
scanning. Every check here is a token scan. That is fine for "does this reach
`@ptrFromInt`" and weak for "is this identifier the target of an assignment" —
compare `checkBody`'s mutation-through-parameter check, a token pattern, with
the Go version's node-level `AssignStmt` inspection.

**The runtime half is not built here.** Go's is ~200 lines because `reflect`
and `encoding/gob` do argument hashing and result serialisation for free. In
Zig, argument hashing via `@typeInfo` would be *better* — static, no `any`, no
encoder — but result serialisation has no `gob` and cached values with pointers
need an allocator story. That is the real remaining cost, and it is the half
this port skips.

## A flaw shared by both

Dependency extraction matches identifiers against top-level names, so a local
shadowing a top-level name creates a false dependency:

```
slowFib with a local named `scale`:            2c718b82d1d5320b
  ... after changing the unrelated top-level `scale`: 1a820a5f0cd9baf8
```

The Go version does the same thing (`d0016bd1` → `c572a67a`). Over-approximating
is the safe direction — a spurious miss, never a stale hit — but the fix needs
real scope resolution. Go has `go/types` for that. Zig has `AstGen`/`Zir`,
which is the compiler's own lowering rather than a name-resolution API you
would want to drive from outside.

## Verified invalidation semantics

Identical to the Go version:

| change | `score` | `slowFib` |
|---|---|---|
| baseline | `7cb20a82` | `035410b0` |
| rewrote doc comment, added `//` comment and blank lines | `7cb20a82` | `035410b0` |
| renamed a local in callee `sum` | `cf1cc1c7` | `035410b0` |
| `const scale` 1000 → 100 (read via `normalise`) | `c732ecee` | `035410b0` |
| added a field to `Weights` | `2825ea98` | `035410b0` |

## Purity checks

Token scans over the transitive declaration set:

- container-level `var` reached from a pure function
- `<import>.<namespace>` not on `pure_namespaces` — allowlisting the import
  alone is useless in Zig, where `std.math` and `std.fs` arrive through the
  same name
- builtins not on `pure_builtins` (`@ptrFromInt`, `@intFromPtr`, `@atomicRmw`, …)
- `asm`, `volatile`
- parameters: `anytype` and function parameters rejected; pointer/slice
  parameters require `///cache:deep <name>`

`example/bad.zig` exercises all of these, including a violation reached only
through a callee (`sneaky` → `helper` → `@intFromPtr` and `call_count`).
