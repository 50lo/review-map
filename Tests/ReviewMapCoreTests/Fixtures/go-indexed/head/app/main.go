package main

import (
	"fmt"

	"example.com/demo/cache"
	"example.com/demo/store"
)

var warm *cache.Cache

func start() {
	s := &store.Store{}
	fmt.Println(s.Load("a"), warm != nil)
}

func main() { start() }
