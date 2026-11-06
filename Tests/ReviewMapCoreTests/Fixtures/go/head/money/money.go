package money

import "fmt"

// Format writes cents as a price.
func Format(cents int) string {
	return fmt.Sprintf("%d.%02d", cents/100, cents%100)
}
