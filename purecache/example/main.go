package main

//go:generate go run purecache/cmd/purecache .

import (
	"fmt"
	"time"

	"purecache/cache"
)

func main() {
	store, err := cache.NewDiskStore(".purecache")
	if err != nil {
		panic(err)
	}
	cache.SetStore(store)

	fmt.Printf("cache identity of SlowFib: %s\n\n", cacheID_SlowFib[:16])

	timed("SlowFib(34)", func() any { return CachedSlowFib(34) })
	timed("SlowFib(34)", func() any { return CachedSlowFib(34) })

	xs := []float64{1, 2, 3, 4, 5}
	w := Weights{Alpha: 2, Beta: 0.5}
	timed("Score", func() any { return CachedScore(xs, w) })
	timed("Score", func() any { return CachedScore(xs, w) })

	// Same contents, different backing array: the key is the contents, so
	// this hits.
	timed("Score (copy)", func() any { return CachedScore([]float64{1, 2, 3, 4, 5}, w) })

	// Different contents: miss.
	timed("Score (changed)", func() any { return CachedScore([]float64{1, 2, 3, 4, 6}, w) })

	// Map arguments are hashed order-independently.
	timed("TotalCount", func() any { return CachedTotalCount(map[string]int{"a": 1, "b": 2}) })
	timed("TotalCount (reordered)", func() any { return CachedTotalCount(map[string]int{"b": 2, "a": 1}) })

	hit, miss := cache.Stats()
	fmt.Printf("\nhits=%d misses=%d\n", hit, miss)
}

func timed(label string, f func() any) {
	before, _ := cache.Stats()
	start := time.Now()
	v := f()
	elapsed := time.Since(start)
	after, _ := cache.Stats()

	status := "MISS"
	if after > before {
		status = "HIT "
	}
	fmt.Printf("%-24s %s %-12v -> %v\n", label, status, elapsed.Round(time.Microsecond), v)
}
