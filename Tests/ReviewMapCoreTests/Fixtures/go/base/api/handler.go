package api

import (
	"fmt"
	"net/http"

	"example.com/shop/cart"
	m "example.com/shop/money"
)

type Handler struct {
	Store cart.Store
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c, err := h.Store.Load(r.URL.Query().Get("id"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	fmt.Fprintln(w, cart.Describe(c), m.Format(c.Total(nil)))
}
