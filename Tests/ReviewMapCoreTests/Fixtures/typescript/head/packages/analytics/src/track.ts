export function track(event: string): void {
  setTimeout(() => console.log(event), 0);
}

export function format(event: string): string {
  return event.toUpperCase();
}
