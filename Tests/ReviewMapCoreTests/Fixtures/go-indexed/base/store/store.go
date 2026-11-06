package store

// Store reads saved values.
type Store struct{}

func (s *Store) Load(key string) string {
	return "store:" + key
}
