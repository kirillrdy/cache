// Package bad collects functions that claim purity but are not pure. Running
// `purecache example/bad` should reject every one of them.
package bad

import (
	"math/rand"
	"os"
	"time"
)

var callCount int

type Buffer struct{ Data []byte }

//cache:pure
func Counter(n int) int {
	callCount++ // reads and writes a package-level var
	return n + callCount
}

//cache:pure
func Stamped(n int) int {
	return n + int(time.Now().Unix()) // reaches outside its arguments
}

//cache:pure
func Noisy(n int) int {
	return n + rand.Intn(10) // not a function of its arguments
}

//cache:pure
func Env(key string) string {
	return os.Getenv(key) // reads ambient state
}

//cache:pure
func Apply(n int, f func(int) int) int {
	return f(n) // a func value has no hashable content
}

//cache:pure
//cache:deep b
func Clobber(b *Buffer) int {
	b.Data = append(b.Data, 1) // mutates through a parameter
	return len(b.Data)
}

//cache:pure
func Unmarked(xs []int) int {
	return len(xs) // reference-typed parameter with no //cache:deep promise
}

//cache:pure
func Concurrent(n int) int {
	ch := make(chan int, 1)
	go func() { ch <- n * 2 }()
	return <-ch
}
