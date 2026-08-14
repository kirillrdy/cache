// Command purecache scans a package for functions marked //cache:pure,
// verifies that the purity claim holds, derives a checksum over each
// function's transitive in-package dependencies, and emits cached wrappers.
//
//	purecache <dir>
//
// The checksum covers, for the target function and every in-package function
// it can reach: the canonical (comment- and position-free) source text of the
// declaration, plus the text of every package-level const and type
// declaration it references. Changing any of those changes the key, which is
// what makes the cache safe to keep on disk across edits.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const genFile = "zz_purecache.go"

// Imported packages whose functions are treated as pure. Everything else is
// rejected: a pure function may not reach os, time, math/rand, sync, io, ...
var pureImports = map[string]bool{
	"math":            true,
	"math/bits":       true,
	"strings":         true,
	"strconv":         true,
	"sort":            true,
	"slices":          true,
	"unicode":         true,
	"unicode/utf8":    true,
	"errors":          true,
	"crypto/sha256":   true,
	"encoding/hex":    true,
	"encoding/binary": true,
}

// fmt is only pure for the formatting entry points.
var pureFmtFuncs = map[string]bool{
	"Sprint": true, "Sprintf": true, "Sprintln": true, "Errorf": true,
}

var builtins = map[string]bool{
	"len": true, "cap": true, "append": true, "make": true, "new": true,
	"copy": true, "delete": true, "min": true, "max": true, "clear": true,
	"panic": true, "complex": true, "real": true, "imag": true,
	// Conversions to predeclared types parse as calls too.
	"int": true, "int8": true, "int16": true, "int32": true, "int64": true,
	"uint": true, "uint8": true, "uint16": true, "uint32": true, "uint64": true,
	"float32": true, "float64": true, "string": true, "byte": true, "rune": true,
	"bool": true, "uintptr": true, "error": true, "any": true,
}

type pkg struct {
	fset  *token.FileSet
	files map[string]*ast.File

	funcs  map[string]*ast.FuncDecl  // package-level funcs by name
	consts map[string]*ast.ValueSpec // package-level consts by name
	types  map[string]*ast.TypeSpec  // package-level types by name
	vars   map[string]bool           // package-level var names (poison)

	fileOf  map[*ast.FuncDecl]*ast.File
	imports map[*ast.File]map[string]string // alias -> path
	name    string

	// warns holds things the analysis cannot prove either way. They do not
	// block generation.
	warns []string
}

// target is a function marked //cache:pure.
type target struct {
	decl *ast.FuncDecl
	deep map[string]bool // params opted into deep content hashing
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: purecache <dir>")
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "purecache:", err)
		os.Exit(1)
	}
}

func run(dir string) error {
	p, err := load(dir)
	if err != nil {
		return err
	}
	targets, err := collectTargets(p)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		fmt.Printf("purecache: no //cache:pure functions in %s\n", dir)
		return nil
	}

	// Directives have been read, so comments can go. They must not be part of
	// any checksum.
	p.stripComments()

	var problems []string
	for _, t := range targets {
		if errs := p.checkPure(t); len(errs) > 0 {
			problems = append(problems, errs...)
		}
	}
	if len(problems) > 0 {
		sort.Strings(problems)
		return fmt.Errorf("purity violations:\n  %s", strings.Join(dedup(problems), "\n  "))
	}
	if len(p.warns) > 0 {
		sort.Strings(p.warns)
		for _, w := range dedup(p.warns) {
			fmt.Fprintln(os.Stderr, "purecache: warning:", w)
		}
	}

	src, err := p.emit(targets)
	if err != nil {
		return err
	}
	out := filepath.Join(dir, genFile)
	if err := os.WriteFile(out, src, 0o644); err != nil {
		return err
	}
	fmt.Printf("purecache: wrote %s (%d function(s))\n", out, len(targets))
	for _, t := range targets {
		fmt.Printf("  %-12s %s\n", t.decl.Name.Name, p.bodyHash(t.decl.Name.Name)[:16])
	}
	return nil
}

// dedup removes adjacent duplicates from a sorted slice. Shared callees are
// analysed once per target, so the same finding can be reported twice.
func dedup(s []string) []string {
	out := s[:0:0]
	for i, v := range s {
		if i == 0 || v != s[i-1] {
			out = append(out, v)
		}
	}
	return out
}

func load(dir string) (*pkg, error) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, dir, func(fi os.FileInfo) bool {
		return fi.Name() != genFile && !strings.HasSuffix(fi.Name(), "_test.go")
	}, parser.ParseComments)
	if err != nil {
		return nil, err
	}
	if len(pkgs) != 1 {
		return nil, fmt.Errorf("expected exactly one package in %s, found %d", dir, len(pkgs))
	}

	p := &pkg{
		fset:    fset,
		files:   map[string]*ast.File{},
		funcs:   map[string]*ast.FuncDecl{},
		consts:  map[string]*ast.ValueSpec{},
		types:   map[string]*ast.TypeSpec{},
		vars:    map[string]bool{},
		fileOf:  map[*ast.FuncDecl]*ast.File{},
		imports: map[*ast.File]map[string]string{},
	}

	for name, apkg := range pkgs {
		p.name = name
		for path, f := range apkg.Files {
			p.files[path] = f
			imp := map[string]string{}
			for _, is := range f.Imports {
				ipath := strings.Trim(is.Path.Value, `"`)
				alias := ipath[strings.LastIndex(ipath, "/")+1:]
				if is.Name != nil {
					alias = is.Name.Name
				}
				imp[alias] = ipath
			}
			p.imports[f] = imp

			for _, d := range f.Decls {
				switch d := d.(type) {
				case *ast.FuncDecl:
					if d.Recv != nil {
						continue // methods are out of scope for the prototype
					}
					p.funcs[d.Name.Name] = d
					p.fileOf[d] = f
				case *ast.GenDecl:
					for _, s := range d.Specs {
						switch s := s.(type) {
						case *ast.ValueSpec:
							for _, n := range s.Names {
								if d.Tok == token.CONST {
									p.consts[n.Name] = s
								} else {
									p.vars[n.Name] = true
								}
							}
						case *ast.TypeSpec:
							p.types[s.Name.Name] = s
						}
					}
				}
			}
		}
	}
	return p, nil
}

func collectTargets(p *pkg) ([]*target, error) {
	var out []*target
	names := make([]string, 0, len(p.funcs))
	for n := range p.funcs {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, n := range names {
		d := p.funcs[n]
		if d.Doc == nil {
			continue
		}
		var pure bool
		deep := map[string]bool{}
		for _, c := range d.Doc.List {
			txt := strings.TrimSpace(strings.TrimPrefix(c.Text, "//"))
			switch {
			case txt == "cache:pure":
				pure = true
			case strings.HasPrefix(txt, "cache:deep "):
				for _, a := range strings.Split(strings.TrimPrefix(txt, "cache:deep "), ",") {
					if a = strings.TrimSpace(a); a != "" {
						deep[a] = true
					}
				}
			}
		}
		if !pure {
			continue
		}
		if d.Body == nil {
			return nil, fmt.Errorf("%s: //cache:pure on a function with no body", p.pos(d))
		}
		out = append(out, &target{decl: d, deep: deep})
	}
	return out, nil
}

// stripComments detaches every comment from the AST. printer emits the Doc and
// Comment fields of the nodes it walks, so leaving them attached would make a
// reworded comment invalidate the cache. Comments that float free inside a
// body are only reachable through File.Comments and never printed, so clearing
// that too is enough.
func (p *pkg) stripComments() {
	for _, f := range p.files {
		f.Comments = nil
		ast.Inspect(f, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.Field:
				n.Doc, n.Comment = nil, nil
			case *ast.ImportSpec:
				n.Doc, n.Comment = nil, nil
			case *ast.ValueSpec:
				n.Doc, n.Comment = nil, nil
			case *ast.TypeSpec:
				n.Doc, n.Comment = nil, nil
			case *ast.GenDecl:
				n.Doc = nil
			case *ast.FuncDecl:
				n.Doc = nil
			}
			return true
		})
	}
}

func (p *pkg) pos(n ast.Node) string {
	pos := p.fset.Position(n.Pos())
	return fmt.Sprintf("%s:%d", filepath.Base(pos.Filename), pos.Line)
}

// ---------------------------------------------------------------- purity ---

// param is one flattened parameter.
type param struct {
	name string
	typ  ast.Expr
}

func params(d *ast.FuncDecl) []param {
	var out []param
	i := 0
	for _, f := range d.Type.Params.List {
		if len(f.Names) == 0 {
			out = append(out, param{name: fmt.Sprintf("_a%d", i), typ: f.Type})
			i++
			continue
		}
		for _, n := range f.Names {
			out = append(out, param{name: n.Name, typ: f.Type})
			i++
		}
	}
	return out
}

// classify decides whether a parameter type can be hashed by value, needs an
// explicit //cache:deep opt-in, or can never be cached.
type argClass int

const (
	argValue argClass = iota // self-contained value: hash it
	argDeep                  // reference: hashable only with an explicit promise
	argNever                 // no observable content, or unbounded aliasing
)

func (p *pkg) classify(e ast.Expr) argClass {
	switch t := e.(type) {
	case *ast.Ident:
		if ts, ok := p.types[t.Name]; ok {
			return p.classify(ts.Type)
		}
		return argValue // predeclared
	case *ast.StarExpr, *ast.MapType:
		return argDeep
	case *ast.ArrayType:
		if t.Len == nil {
			return argDeep // slice
		}
		return p.classify(t.Elt) // array
	case *ast.StructType:
		worst := argValue
		for _, f := range t.Fields.List {
			if c := p.classify(f.Type); c > worst {
				worst = c
			}
		}
		return worst
	case *ast.SelectorExpr:
		// Type from another package; we cannot see its definition.
		return argDeep
	case *ast.ChanType, *ast.FuncType, *ast.InterfaceType:
		return argNever
	case *ast.Ellipsis:
		return argDeep
	}
	return argNever
}

func (p *pkg) checkPure(t *target) []string {
	var errs []string
	d := t.decl

	if d.Type.Results == nil || len(d.Type.Results.List) != 1 || len(d.Type.Results.List[0].Names) > 1 {
		errs = append(errs, fmt.Sprintf("%s: %s must return exactly one value", p.pos(d), d.Name.Name))
	}

	for _, pa := range params(d) {
		switch p.classify(pa.typ) {
		case argNever:
			errs = append(errs, fmt.Sprintf("%s: %s: parameter %q has type %s, which has no hashable content",
				p.pos(d), d.Name.Name, pa.name, exprString(p.fset, pa.typ)))
		case argDeep:
			if !t.deep[pa.name] {
				errs = append(errs, fmt.Sprintf("%s: %s: parameter %q is a reference type (%s); add `//cache:deep %s` to promise it is not mutated and may be hashed by content",
					p.pos(d), d.Name.Name, pa.name, exprString(p.fset, pa.typ), pa.name))
			}
		}
	}

	seen := map[string]bool{}
	var walk func(name string)
	walk = func(name string) {
		if seen[name] {
			return
		}
		seen[name] = true
		fd := p.funcs[name]
		if fd == nil || fd.Body == nil {
			return
		}
		errs = append(errs, p.checkBody(fd)...)
		for _, callee := range p.calls(fd) {
			walk(callee)
		}
	}
	walk(d.Name.Name)
	return errs
}

// checkBody reports effects that make a single function body impure.
func (p *pkg) checkBody(d *ast.FuncDecl) []string {
	var errs []string
	add := func(n ast.Node, format string, a ...any) {
		errs = append(errs, fmt.Sprintf("%s: %s: %s", p.pos(n), d.Name.Name, fmt.Sprintf(format, a...)))
	}

	paramNames := map[string]bool{}
	paramTypes := map[string]ast.Expr{}
	for _, pa := range params(d) {
		paramNames[pa.name] = true
		paramTypes[pa.name] = pa.typ
	}
	imports := p.imports[p.fileOf[d]]

	isMap := func(e ast.Expr) bool {
		if id, ok := e.(*ast.Ident); ok {
			if ts, ok := p.types[id.Name]; ok {
				e = ts.Type
			}
		}
		_, ok := e.(*ast.MapType)
		return ok
	}

	ast.Inspect(d.Body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.GoStmt:
			add(n, "starts a goroutine")
		case *ast.SelectStmt:
			add(n, "uses select")
		case *ast.SendStmt:
			add(n, "sends on a channel")
		case *ast.UnaryExpr:
			if n.Op == token.ARROW {
				add(n, "receives from a channel")
			}
		case *ast.Ident:
			if p.vars[n.Name] {
				add(n, "reads or writes package-level var %q", n.Name)
			}
		case *ast.AssignStmt:
			for _, lhs := range n.Lhs {
				if root, ok := mutationRoot(lhs); ok && paramNames[root] {
					add(n, "mutates through parameter %q", root)
				}
			}
		case *ast.IncDecStmt:
			if root, ok := mutationRoot(n.X); ok && paramNames[root] {
				add(n, "mutates through parameter %q", root)
			}
		case *ast.RangeStmt:
			// Map iteration order is unspecified. Whether that matters depends
			// on whether the loop body accumulates commutatively, which this
			// analysis cannot decide -- so warn rather than reject.
			if id, ok := n.X.(*ast.Ident); ok {
				if t, isParam := paramTypes[id.Name]; isParam && isMap(t) {
					p.warns = append(p.warns, fmt.Sprintf(
						"%s: %s: ranges over map %q; iteration order is unspecified, so the result is only reproducible if the loop body is order-independent",
						p.pos(n), d.Name.Name, id.Name))
				}
			}
		case *ast.CallExpr:
			switch fn := n.Fun.(type) {
			case *ast.Ident:
				if builtins[fn.Name] || p.funcs[fn.Name] != nil || p.types[fn.Name] != nil {
					return true
				}
				add(n, "calls unknown function %q", fn.Name)
			case *ast.SelectorExpr:
				x, ok := fn.X.(*ast.Ident)
				if !ok {
					add(n, "calls a method (not analysable in this prototype)")
					return true
				}
				path, isImport := imports[x.Name]
				if !isImport {
					add(n, "calls a method on %q (not analysable in this prototype)", x.Name)
					return true
				}
				if path == "fmt" {
					if !pureFmtFuncs[fn.Sel.Name] {
						add(n, "calls fmt.%s, which does I/O", fn.Sel.Name)
					}
					return true
				}
				if !pureImports[path] {
					add(n, "calls into %q, which is not on the pure-import list", path)
				}
			case *ast.FuncLit:
				// Immediately-invoked literal: its body is inspected anyway.
			default:
				add(n, "calls a function value")
			}
		}
		return true
	})
	return errs
}

// mutationRoot returns the base identifier of an assignable expression when
// the assignment writes through a reference (*p, p.f, p[i]), rather than
// rebinding a local.
func mutationRoot(e ast.Expr) (string, bool) {
	switch e := e.(type) {
	case *ast.StarExpr:
		return rootIdent(e.X)
	case *ast.SelectorExpr:
		return rootIdent(e.X)
	case *ast.IndexExpr:
		return rootIdent(e.X)
	}
	return "", false
}

func rootIdent(e ast.Expr) (string, bool) {
	for {
		switch x := e.(type) {
		case *ast.Ident:
			return x.Name, true
		case *ast.SelectorExpr:
			e = x.X
		case *ast.IndexExpr:
			e = x.X
		case *ast.StarExpr:
			e = x.X
		case *ast.ParenExpr:
			e = x.X
		default:
			return "", false
		}
	}
}

// calls returns the names of in-package functions called by d.
func (p *pkg) calls(d *ast.FuncDecl) []string {
	set := map[string]bool{}
	ast.Inspect(d.Body, func(n ast.Node) bool {
		if c, ok := n.(*ast.CallExpr); ok {
			if id, ok := c.Fun.(*ast.Ident); ok && p.funcs[id.Name] != nil {
				set[id.Name] = true
			}
		}
		return true
	})
	out := make([]string, 0, len(set))
	for n := range set {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// -------------------------------------------------------------- checksum ---

// bodyHash is the function's identity: a checksum over the canonical text of
// the function and of every in-package function, const and type declaration it
// transitively depends on.
func (p *pkg) bodyHash(name string) string {
	var units []string
	seenFn := map[string]bool{}
	seenDecl := map[string]bool{}

	var visit func(string)
	visit = func(fn string) {
		if seenFn[fn] {
			return
		}
		seenFn[fn] = true
		d := p.funcs[fn]
		if d == nil {
			return
		}
		units = append(units, "func "+fn+"\x00"+exprString(p.fset, d))

		// Referenced package-level consts and types travel with the body: a
		// changed const or a changed struct field changes the result.
		ast.Inspect(d, func(n ast.Node) bool {
			id, ok := n.(*ast.Ident)
			if !ok {
				return true
			}
			if vs, ok := p.consts[id.Name]; ok && !seenDecl["c:"+id.Name] {
				seenDecl["c:"+id.Name] = true
				units = append(units, "const "+id.Name+"\x00"+exprString(p.fset, vs))
			}
			if ts, ok := p.types[id.Name]; ok && !seenDecl["t:"+id.Name] {
				seenDecl["t:"+id.Name] = true
				units = append(units, "type "+id.Name+"\x00"+exprString(p.fset, ts))
			}
			return true
		})

		for _, callee := range p.calls(d) {
			visit(callee)
		}
	}
	visit(name)

	sort.Strings(units) // order of discovery must not affect the key
	h := sha256.New()
	for _, u := range units {
		fmt.Fprintf(h, "%d:", len(u))
		h.Write([]byte(u))
	}
	return hex.EncodeToString(h.Sum(nil))
}

// exprString renders a node canonically: gofmt-normalised, no comments, no
// blank lines, no positions. Reformatting or re-commenting a function must not
// invalidate its cache; changing a token must.
func exprString(fset *token.FileSet, n ast.Node) string {
	var buf bytes.Buffer
	cfg := printer.Config{Mode: printer.RawFormat, Tabwidth: 8}
	if err := cfg.Fprint(&buf, fset, n); err != nil {
		return fmt.Sprintf("<unprintable: %v>", err)
	}
	// printer reproduces the source's blank lines from node positions. They
	// carry no meaning, so drop them.
	lines := strings.Split(buf.String(), "\n")
	kept := lines[:0]
	for _, l := range lines {
		if strings.TrimSpace(l) != "" {
			kept = append(kept, strings.TrimRight(l, " \t"))
		}
	}
	return strings.Join(kept, "\n")
}

// ------------------------------------------------------------------ emit ---

func (p *pkg) emit(targets []*target) ([]byte, error) {
	var b bytes.Buffer
	fmt.Fprintf(&b, "// Code generated by purecache. DO NOT EDIT.\n\n")
	fmt.Fprintf(&b, "package %s\n\n", p.name)
	fmt.Fprintf(&b, "import \"purecache/cache\"\n\n")

	for _, t := range targets {
		d := t.decl
		name := d.Name.Name
		ps := params(d)
		ret := exprString(p.fset, d.Type.Results.List[0].Type)

		fmt.Fprintf(&b, "const cacheID_%s = %q\n\n", name, p.bodyHash(name))

		fmt.Fprintf(&b, "type cacheArgs_%s struct {\n", name)
		for i, pa := range ps {
			fmt.Fprintf(&b, "\tA%d %s\n", i, exprString(p.fset, pa.typ))
		}
		fmt.Fprintf(&b, "}\n\n")

		var sig, fwd []string
		for i, pa := range ps {
			sig = append(sig, fmt.Sprintf("%s %s", pa.name, exprString(p.fset, pa.typ)))
			fwd = append(fwd, fmt.Sprintf("a.A%d", i))
		}
		var pass []string
		for _, pa := range ps {
			pass = append(pass, pa.name)
		}

		fmt.Fprintf(&b, "// %s is the memoised form of %s.\n", wrapperName(name), name)
		fmt.Fprintf(&b, "func %s(%s) %s {\n", wrapperName(name), strings.Join(sig, ", "), ret)
		fmt.Fprintf(&b, "\treturn cache.Do(cacheID_%s, cacheArgs_%s{%s}, func(a cacheArgs_%s) %s {\n",
			name, name, strings.Join(pass, ", "), name, ret)
		fmt.Fprintf(&b, "\t\treturn %s(%s)\n", name, strings.Join(fwd, ", "))
		fmt.Fprintf(&b, "\t})\n}\n\n")
	}

	return format.Source(b.Bytes())
}

func wrapperName(n string) string {
	return "Cached" + strings.ToUpper(n[:1]) + n[1:]
}
