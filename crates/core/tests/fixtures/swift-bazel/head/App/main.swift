import Feed
import Storage

let feed = Feed(store: Store())
print(feed.items().count, feed.cached().count)
