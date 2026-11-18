export class Store {
  private value = 1;

  load(): number {
    return this.value * 2;
  }

  reset(): void {
    this.value = 0;
  }
}
