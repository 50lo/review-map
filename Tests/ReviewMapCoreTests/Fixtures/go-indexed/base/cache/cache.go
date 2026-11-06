package cache

// Cache keeps values in memory.
type Cache struct{}

func (c *Cache) Load(key string) string {
	return "cache:" + key
}
