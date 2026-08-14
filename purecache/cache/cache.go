// Package cache is the runtime half of purecache.
//
// The compile-time half (cmd/purecache) derives a stable identity for a
// function -- a checksum over its body plus everything in its package that the
// body transitively depends on -- and emits wrappers that call Do with that
// identity. Do turns (identity, arguments) into a cache key.
package cache

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/gob"
	"encoding/hex"
	"fmt"
	"hash"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"sync/atomic"
)

// Store is the backing key/value store. Keys are hex sha256, values are
// gob-encoded results.
type Store interface {
	Get(key string) ([]byte, bool)
	Put(key string, val []byte) error
}

// MemStore is a process-local store.
type MemStore struct {
	mu sync.RWMutex
	m  map[string][]byte
}

func NewMemStore() *MemStore { return &MemStore{m: map[string][]byte{}} }

func (s *MemStore) Get(key string) ([]byte, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.m[key]
	return v, ok
}

func (s *MemStore) Put(key string, val []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[key] = val
	return nil
}

// DiskStore persists entries under a directory, one file per key, so the cache
// survives across processes.
type DiskStore struct{ dir string }

func NewDiskStore(dir string) (*DiskStore, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &DiskStore{dir: dir}, nil
}

func (s *DiskStore) path(key string) string {
	return filepath.Join(s.dir, key[:2], key[2:])
}

func (s *DiskStore) Get(key string) ([]byte, bool) {
	b, err := os.ReadFile(s.path(key))
	if err != nil {
		return nil, false
	}
	return b, true
}

func (s *DiskStore) Put(key string, val []byte) error {
	p := s.path(key)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, val, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

var (
	storeMu sync.RWMutex
	store   Store = NewMemStore()

	hits   atomic.Int64
	misses atomic.Int64
)

// SetStore swaps the backing store. Not safe to call concurrently with Do.
func SetStore(s Store) {
	storeMu.Lock()
	defer storeMu.Unlock()
	store = s
}

// Stats reports hit/miss counts since process start.
func Stats() (hit, miss int64) { return hits.Load(), misses.Load() }

// Do memoises fn. id is the generated body checksum; args is the generated
// argument struct. A key that cannot be derived (an argument type the hasher
// refuses, e.g. a func value) falls through to an uncached call rather than
// returning something wrong.
func Do[A any, R any](id string, args A, fn func(A) R) R {
	key, err := Key(id, args)
	if err != nil {
		misses.Add(1)
		return fn(args)
	}

	storeMu.RLock()
	s := store
	storeMu.RUnlock()

	if raw, ok := s.Get(key); ok {
		var out R
		if err := gob.NewDecoder(bytes.NewReader(raw)).Decode(&out); err == nil {
			hits.Add(1)
			return out
		}
		// Corrupt or stale-encoding entry: fall through and overwrite.
	}

	misses.Add(1)
	out := fn(args)

	var buf bytes.Buffer
	if err := gob.NewEncoder(&buf).Encode(out); err == nil {
		_ = s.Put(key, buf.Bytes())
	}
	return out
}

// Key derives the cache key for a call: sha256 over the function identity and
// a canonical encoding of the arguments.
func Key(id string, args any) (string, error) {
	h := sha256.New()
	writeStr(h, id)
	if err := hashValue(h, reflect.ValueOf(args)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func writeStr(h hash.Hash, s string) {
	var n [8]byte
	binary.LittleEndian.PutUint64(n[:], uint64(len(s)))
	h.Write(n[:])
	h.Write([]byte(s))
}

func writeU64(h hash.Hash, v uint64) {
	var n [8]byte
	binary.LittleEndian.PutUint64(n[:], v)
	h.Write(n[:])
}

// hashValue writes a canonical, type-tagged encoding of v.
//
// Canonical means: two values hash the same iff they are indistinguishable to
// a pure function. So map keys are sorted, pointers are followed (identity is
// not observable to a pure function, contents are), and NaN is normalised to a
// single bit pattern.
func hashValue(h hash.Hash, v reflect.Value) error {
	if !v.IsValid() {
		h.Write([]byte{0xff})
		return nil
	}
	t := v.Type()
	writeStr(h, t.String())

	switch v.Kind() {
	case reflect.Bool:
		if v.Bool() {
			h.Write([]byte{1})
		} else {
			h.Write([]byte{0})
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		writeU64(h, uint64(v.Int()))
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		writeU64(h, v.Uint())
	case reflect.Float32, reflect.Float64:
		f := v.Float()
		if math.IsNaN(f) {
			// All NaNs are the same value as far as a caller can tell.
			writeU64(h, 0x7ff8000000000001)
			return nil
		}
		if f == 0 {
			f = 0 // collapse -0.0 and +0.0
		}
		writeU64(h, math.Float64bits(f))
	case reflect.Complex64, reflect.Complex128:
		c := v.Complex()
		writeU64(h, math.Float64bits(real(c)))
		writeU64(h, math.Float64bits(imag(c)))
	case reflect.String:
		writeStr(h, v.String())
	case reflect.Array, reflect.Slice:
		if v.Kind() == reflect.Slice && v.IsNil() {
			h.Write([]byte{0xff})
			return nil
		}
		// Fast path: []byte and friends.
		if v.Type().Elem().Kind() == reflect.Uint8 && v.Kind() == reflect.Slice {
			writeU64(h, uint64(v.Len()))
			h.Write(v.Bytes())
			return nil
		}
		writeU64(h, uint64(v.Len()))
		for i := 0; i < v.Len(); i++ {
			if err := hashValue(h, v.Index(i)); err != nil {
				return err
			}
		}
	case reflect.Map:
		if v.IsNil() {
			h.Write([]byte{0xff})
			return nil
		}
		// Iteration order is not observable to a pure function, so sort by the
		// hash of each entry.
		entries := make([]string, 0, v.Len())
		iter := v.MapRange()
		for iter.Next() {
			eh := sha256.New()
			if err := hashValue(eh, iter.Key()); err != nil {
				return err
			}
			if err := hashValue(eh, iter.Value()); err != nil {
				return err
			}
			entries = append(entries, string(eh.Sum(nil)))
		}
		sort.Strings(entries)
		writeU64(h, uint64(len(entries)))
		for _, e := range entries {
			h.Write([]byte(e))
		}
	case reflect.Struct:
		writeU64(h, uint64(v.NumField()))
		for i := 0; i < v.NumField(); i++ {
			writeStr(h, t.Field(i).Name)
			// Reading unexported fields is fine as long as we never call
			// Interface() on them.
			if err := hashValue(h, v.Field(i)); err != nil {
				return err
			}
		}
	case reflect.Pointer:
		if v.IsNil() {
			h.Write([]byte{0xff})
			return nil
		}
		h.Write([]byte{1})
		return hashValue(h, v.Elem())
	case reflect.Interface:
		// The generator rejects interface-typed arguments, but Do is also
		// callable by hand.
		if v.IsNil() {
			h.Write([]byte{0xff})
			return nil
		}
		return hashValue(h, v.Elem())
	default:
		// Chan, Func, UnsafePointer: value has no content to hash.
		return fmt.Errorf("purecache: cannot hash %s (kind %s)", t, v.Kind())
	}
	return nil
}
