pub mod store;
pub trait Store { fn get(&self) -> i32; }
pub struct Item { pub value: i32 }
pub fn read() -> i32 { store::value() }
