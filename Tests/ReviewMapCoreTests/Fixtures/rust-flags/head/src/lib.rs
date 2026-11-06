pub fn added() {}
pub fn signature(x: u64) {}
pub(crate) fn narrowed() {}
pub async fn become_async() {}
pub fn become_sync() {}
pub fn add_bounds<T: Send + Sync>(x: T) {}
pub fn remove_bounds<T>(x: T) {}
pub trait Service {
    fn added(&self);
    fn changed(&self, x: u64);
}
pub enum Color { Red, Blue }
pub enum Flexible { A }
#[non_exhaustive]
pub enum Strict { A }
#[derive(Serialize, Deserialize)]
pub struct Wire {
    pub id: u64,
    pub new: String,
}
#[serde(rename_all = "camelCase")]
pub struct Named { pub id: u32 }
mod hidden { pub fn secret(x: u32) {} }
#[derive(Serialize)]
pub enum Message { Named { value: u64 }, Tuple(u64) }
#[derive(Serialize)]
pub struct TupleWire(pub u64);
