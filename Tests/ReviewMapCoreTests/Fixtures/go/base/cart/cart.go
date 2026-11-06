package cart

import (
	"errors"

	"github.com/google/uuid"
)

// Store loads and saves carts.
type Store interface {
	Load(id string) (*Cart, error)
	Save(c *Cart) error
}

type Item struct {
	SKU string `json:"sku"`
	Qty int    `json:"qty"`
}

type Cart struct {
	ID    string
	Items []Item
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
	return nil
}

func (c *Cart) Total(prices map[string]int) int {
	total := 0
	for _, it := range c.Items {
		total += prices[it.SKU] * it.Qty
	}
	return total
}

func Describe(c *Cart) string {
	return c.ID
}
