pub trait Render {
    fn render(&self) -> u32;
}
pub struct Alpha;
pub struct Beta;
impl Render for Alpha {
    fn render(&self) -> u32 { 1 }
}
impl Render for Beta {
    fn render(&self) -> u32 { 2 }
}
