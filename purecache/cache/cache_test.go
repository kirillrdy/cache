package cache

import "testing"

func mustKey(t *testing.T, args any) string {
	t.Helper()
	k, err := Key("id", args)
	if err != nil {
		t.Fatalf("Key(%#v): %v", args, err)
	}
	return k
}

func TestKeyIsContentAddressed(t *testing.T) {
	a, b := 1, 1
	c := 2

	same := []struct {
		name string
		x, y any
	}{
		{"identical scalars", 42, 42},
		{"distinct pointers to equal values", &a, &b},
		{"slices with different backing arrays", []int{1, 2, 3}, []int{1, 2, 3}},
		{"maps built in different orders",
			map[string]int{"a": 1, "b": 2, "c": 3},
			map[string]int{"c": 3, "b": 2, "a": 1}},
		{"structs with equal unexported fields",
			struct{ v int }{7}, struct{ v int }{7}},
	}
	for _, tc := range same {
		if mustKey(t, tc.x) != mustKey(t, tc.y) {
			t.Errorf("%s: keys differ, want equal", tc.name)
		}
	}

	differ := []struct {
		name string
		x, y any
	}{
		{"different scalars", 42, 43},
		{"pointers to different values", &a, &c},
		{"reordered slices", []int{1, 2}, []int{2, 1}},
		{"different map values", map[string]int{"a": 1}, map[string]int{"a": 2}},
		{"nil vs empty slice", []int(nil), []int{}},
		// The type is part of the key: 1 and int64(1) are not interchangeable.
		{"same bits, different type", int32(1), int64(1)},
	}
	for _, tc := range differ {
		if mustKey(t, tc.x) == mustKey(t, tc.y) {
			t.Errorf("%s: keys equal, want different", tc.name)
		}
	}
}

func TestKeyDependsOnIdentity(t *testing.T) {
	k1, _ := Key("hash-of-body-v1", 5)
	k2, _ := Key("hash-of-body-v2", 5)
	if k1 == k2 {
		t.Error("same key for different function identities")
	}
}

func TestUnhashableArgIsRejected(t *testing.T) {
	if _, err := Key("id", func() {}); err == nil {
		t.Error("want error for a func-valued argument, got nil")
	}
	if _, err := Key("id", struct{ C chan int }{make(chan int)}); err == nil {
		t.Error("want error for a chan-valued field, got nil")
	}
}

func TestDoFallsBackWhenArgsAreUnhashable(t *testing.T) {
	SetStore(NewMemStore())
	calls := 0
	f := func(a struct{ F func() int }) int { calls++; return a.F() }
	arg := struct{ F func() int }{func() int { return 3 }}

	if got := Do("id", arg, f); got != 3 {
		t.Fatalf("got %d, want 3", got)
	}
	if got := Do("id", arg, f); got != 3 {
		t.Fatalf("got %d, want 3", got)
	}
	if calls != 2 {
		t.Errorf("calls = %d, want 2 (an unhashable argument must never be served from cache)", calls)
	}
}

func TestDoMemoises(t *testing.T) {
	SetStore(NewMemStore())
	calls := 0
	f := func(n int) int { calls++; return n * 2 }

	for i := 0; i < 3; i++ {
		if got := Do("id", 21, f); got != 42 {
			t.Fatalf("got %d, want 42", got)
		}
	}
	if calls != 1 {
		t.Errorf("calls = %d, want 1", calls)
	}

	// A different identity must not reuse the entry.
	Do("other-id", 21, f)
	if calls != 2 {
		t.Errorf("calls = %d, want 2", calls)
	}
}
