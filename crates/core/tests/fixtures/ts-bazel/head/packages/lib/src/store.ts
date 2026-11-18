export class Store {
  private value = 1;

  load(): number {
    return this.value * 2;
  }
}

/// An implementation without the parameter still satisfies the new signature, so head builds.
export interface Source {
  fetch(limit?: number): number;
}
