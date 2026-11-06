package cart

import (
	"errors"

	"github.com/google/uuid"
)

// Store loads and saves carts.
type Store interface {
	Load(id string) (*Cart, error)
	Save(c *Cart) error
	Clear(id string) error
}

type Item struct {
	SKU string `json:"id"`
	Qty int    `json:"qty"`
}

type Cart struct {
	ID    string
	Items []Item
	Note  string
}

// ErrEmpty is returned for a cart without items.
var ErrEmpty = errors.New("empty cart")

const MaxItems = 50

func New() *Cart {
	return &Cart{ID: uuid.NewString()}
}

func (c *Cart) Add(item Item) error {
	if item.Qty <= 0 {
		return errors.New("quantity must be positive")
	}
	c.Items = append(c.Items, item)
	_ = c.check()
	go notify(c)
	return nil
}

func (c *Cart) Total(prices map[string]int, discount int) int {
	total := 0
	for _, it := range c.Items {
		total += prices[it.SKU] * it.Qty
	}
	return total - discount
}

func (c *Cart) check() error {
	if len(c.Items) > MaxItems {
		return ErrEmpty
	}
	return nil
}

func notify(c *Cart) {}

func describe(c *Cart) string {
	return c.ID
}
