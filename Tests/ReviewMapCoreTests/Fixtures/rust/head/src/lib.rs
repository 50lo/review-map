pub mod store;
pub trait Store { fn get(&self) -> i64; }
pub struct Item { pub value: i64 }
pub async fn read() -> i32 { store::value() + 1 }
