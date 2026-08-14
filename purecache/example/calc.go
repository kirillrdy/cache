package main

// scale is a package-level const. It is folded into the checksum of any
// function that reads it, directly or through a callee.
const scale = 1000.0

// Weights is a package-level type. Adding or renaming a field changes the
// checksum of every pure function whose signature or body mentions it.
type Weights struct {
	Alpha float64
	Beta  float64
}

//cache:pure
func SlowFib(n int) int {
	if n < 2 {
		return n
	}
	return SlowFib(n-1) + SlowFib(n-2)
}

// Score depends on sum, normalise, scale and Weights. All four are part of its
// cache identity.
//
//cache:pure
//cache:deep xs
func Score(xs []float64, w Weights) float64 {
	return normalise(sum(xs))*w.Alpha + float64(len(xs))*w.Beta
}

// TotalCount sums a map. Order does not matter here, but the generator cannot
// prove that, so it warns.
//
//cache:pure
//cache:deep counts
func TotalCount(counts map[string]int) int {
	total := 0
	for _, v := range counts {
		total += v
	}
	return total
}

func sum(xs []float64) float64 {
	total := 0.0
	for _, x := range xs {
		total += x
	}
	return total
}

func normalise(v float64) float64 {
	return v / scale
}
