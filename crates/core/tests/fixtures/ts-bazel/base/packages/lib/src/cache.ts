export class Cache {
  private hits = 0;

  load(): number {
    return this.hits;
  }
}
