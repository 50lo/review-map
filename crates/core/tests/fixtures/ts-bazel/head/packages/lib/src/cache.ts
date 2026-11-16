export class Cache {
  private hits = 0;

  load(): number {
    this.hits += 1;
    return this.hits;
  }
}

/// Not exported from the package: a second interface named Source, with its own implementation.
export interface Source {
  fetch(): number;
}

export class CacheSource implements Source {
  fetch(): number {
    return 2;
  }
}
