export class Store {
  private value = 1;

  load(): number {
    return this.value;
  }
}

export interface Source {
  fetch(): number;
}
