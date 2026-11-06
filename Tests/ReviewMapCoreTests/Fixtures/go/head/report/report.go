package report

import (
	"fmt"

	"example.com/shop/cart"
	"golang.org/x/text/language"
)

// Summary describes a cart for people.
func Summary(v any) string {
	c := v.(*cart.Cart)
	return fmt.Sprintf("%s: %d items (%s)", c.ID, len(c.Items), language.English)
}
