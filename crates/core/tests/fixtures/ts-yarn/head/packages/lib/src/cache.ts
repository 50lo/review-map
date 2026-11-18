export class Cache {
  private hits = 0;

  load(): number {
    this.hits += 1;
    return this.hits;
  }
}
