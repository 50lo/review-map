pub fn removed() {}
pub fn signature(x: u32) {}
pub fn narrowed() {}
pub fn become_async() {}
pub async fn become_sync() {}
pub fn add_bounds<T>(x: T) {}
pub fn remove_bounds<T: Send + Sync>(x: T) {}
pub trait Service {
    fn removed(&self);
    fn changed(&self, x: u32);
}
pub enum Color { Red, Green }
#[non_exhaustive]
pub enum Flexible { A }
pub enum Strict { A }
#[derive(Serialize, Deserialize)]
pub struct Wire {
    pub id: u32,
    pub old: u32,
}
#[serde(rename_all = "snake_case")]
pub struct Named { pub id: u32 }
mod hidden { pub fn secret() {} }
#[derive(Serialize)]
pub enum Message { Named { value: u32 }, Tuple(u32) }
#[derive(Serialize)]
pub struct TupleWire(pub u32);
