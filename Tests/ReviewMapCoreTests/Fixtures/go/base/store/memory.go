package store

import (
	"sync"

	"example.com/shop/cart"
)

// Memory keeps carts in memory.
type Memory struct {
	mu    sync.Mutex
	carts map[string]*cart.Cart
}

func (m *Memory) Load(id string) (*cart.Cart, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.carts[id], nil
}

func (m *Memory) Save(c *cart.Cart) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.carts[c.ID] = c
	return nil
}
