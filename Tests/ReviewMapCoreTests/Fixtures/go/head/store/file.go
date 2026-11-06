package store

import (
	"encoding/json"
	"os"

	"example.com/shop/cart"
)

// File keeps carts in JSON files.
type File struct {
	Dir string
}

func (f File) Load(id string) (*cart.Cart, error) {
	data, err := os.ReadFile(f.Dir + "/" + id)
	if err != nil {
		return nil, err
	}
	var c cart.Cart
	err = json.Unmarshal(data, &c)
	return &c, err
}

func (f File) Save(c *cart.Cart) error {
	data, _ := json.Marshal(c)
	return os.WriteFile(f.Dir+"/"+c.ID, data, 0o644)
}
