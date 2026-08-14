# purecache

A prototype of function-call caching keyed on a checksum of the function's body
and its arguments, with purity annotations that the tool verifies rather than
trusts.

```
cmd/purecache/   code generator: purity checker + body checksummer + emitter
cache/           runtime: argument hashing, key derivation, stores
example/         demo package with pure functions
example/bad/     functions that claim purity but aren't; all must be rejected
```

## Try it

```sh
go test ./cache/
go run ./cmd/purecache ./example        # generate wrappers
cd example && rm -rf .purecache && go run . && go run .
go run ./cmd/purecache ./example/bad    # exits 1 with 13 violations
```

## The key

```
key = sha256( function_identity || canonical_encoding(arguments) )
```

### function_identity

Not the checksum of one function body. A cache keyed on that goes stale the
moment a callee changes. `function_identity` is a checksum over the canonical
source text of the target function **and of everything in the package it
transitively reaches**: called functions, referenced package-level consts, and
referenced type declarations.

Canonical means gofmt-normalised with comments and blank lines removed, so
reformatting or rewording a comment does not invalidate the cache, while
changing any token does. Verified:

| change                                        | `Score` | `SlowFib` |
|-----------------------------------------------|---------|-----------|
| baseline                                       | `b5672874` | `0adee41d` |
| rewrote a doc comment, added blank lines       | `b5672874` | `0adee41d` |
| renamed a local in the callee `sum`            | `e157c666` | `0adee41d` |
| `const scale` 1000 → 100 (read via `normalise`)| `eeb1971b` | `0adee41d` |
| added a field to `type Weights`                | `eb1dda21` | `0adee41d` |

The unit list is sorted before hashing, so discovery order cannot affect the
key. Recursion is cycle-safe.

### canonical_encoding(arguments)

Type-tagged, and canonical in the sense that two values encode identically iff
a pure function cannot tell them apart:

- pointers are followed — a pure function observes contents, not addresses
- map entries are sorted by entry hash — iteration order is unobservable
- `NaN` collapses to one bit pattern, `-0.0` to `+0.0`
- the type name is part of the encoding, so `int32(1)` ≠ `int64(1)`
- unexported struct fields are included (read via `reflect` without `Interface()`)

## Marking arguments pure

An argument is safe to hash when hashing its value fully determines the
function's behaviour on it. Parameters are classified:

- **value types** (numbers, strings, arrays, structs of those) — hashed as-is,
  no annotation needed
- **reference types** (pointer, slice, map, foreign named type) — require an
  explicit `//cache:deep <names>`. That directive is a promise by the author:
  *the callee does not mutate this, and no one else mutates it for the lifetime
  of the entry*. The tool checks the first half; the second is unprovable
  locally and is what the annotation is actually buying.
- **func, chan, interface** — rejected. No hashable content.

```go
//cache:pure
//cache:deep xs
func Score(xs []float64, w Weights) float64 { ... }
```

`Weights` is a struct of floats, so it needs no annotation. Omitting
`//cache:deep xs` is an error, not a silent pass:

```
calc.go:29: Score: parameter "xs" is a reference type ([]float64);
  add `//cache:deep xs` to promise it is not mutated and may be hashed by content
```

## What the purity checker rejects

Checked transitively over every in-package callee:

- reading or writing a package-level `var`
- calling into a package not on the pure-import allowlist (`os`, `time`,
  `math/rand`, `sync`, `io`, ... are all out; `math`, `strings`, `strconv`,
  `sort`, `slices`, `unicode`, `errors` are in; `fmt` only for `Sprint*`/`Errorf`)
- calling an unresolvable function, a method, or a func value
- assigning through a parameter (`*p = x`, `p.f = x`, `p[i] = x`)
- `go`, `select`, channel send/receive
- the argument-class rules above

Ranging over a map parameter is a **warning**, not an error: order matters only
if the loop body accumulates non-commutatively, and this analysis can't decide
that.

`example/bad/` exercises all of these; the generator rejects every function in
it.

## Generated code

```go
const cacheID_Score = "b567287423c2d6a5..."

type cacheArgs_Score struct {
	A0 []float64
	A1 Weights
}

func CachedScore(xs []float64, w Weights) float64 {
	return cache.Do(cacheID_Score, cacheArgs_Score{xs, w}, func(a cacheArgs_Score) float64 {
		return Score(a.A0, a.A1)
	})
}
```

Arguments are packed into a struct so one generic `Do[A, R]` handles any
arity. Callers opt in by calling `CachedScore` instead of `Score`; the original
stays callable and uncached.

## Known limits of the prototype

- **Single package.** Callees in other packages are invisible to the checksum,
  so a pure function may only call within its package or into the allowlist.
  Lifting this means walking imported packages' ASTs, or hashing export data.
- **No methods.** Only package-level funcs, and only ones returning exactly one
  value.
- **Shadowing.** A local named the same as a package-level `var` is a false
  positive; resolving it properly means `go/types` rather than name matching.
- **Allowlist is trust, not proof.** `pureImports` asserts that e.g. all of
  `strings` is pure. True today, unchecked.
- **Values must be gob-encodable**, so unexported fields are dropped from
  cached results.
- **No eviction, no size bound, no TTL** on `DiskStore`.
- `Do` falls back to an uncached call when a key can't be derived, rather than
  returning something wrong.

## Go vs Zig

See `../zigcache/` for the same analyser written against `std.zig.Ast`, and
`../zigcache/README.md` for the measured comparison. Short version: the
analyser half is *better* in Zig, the runtime half is much cheaper in Go.

An earlier draft of this file claimed the transitive checksum would need a
hand-rolled Zig parser. That was wrong — `std.zig.Ast` is a complete parser
with a canonical printer and typed accessors, and the port is 398 lines against
this file's 685.
