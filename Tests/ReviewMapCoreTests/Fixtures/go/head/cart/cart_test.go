package cart

import "testing"

func TestAdd(t *testing.T) {
	c := New()
	if err := c.Add(Item{SKU: "a", Qty: 1}); err != nil {
		t.Fatal(err)
	}
}
