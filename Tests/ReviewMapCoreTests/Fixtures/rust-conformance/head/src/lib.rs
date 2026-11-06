pub trait Required { fn old(&self); fn added(&self); }
pub struct Missing;
pub struct Complete;
impl Required for Missing { fn old(&self) {} }
impl Required for Complete { fn old(&self) {} fn added(&self) {} }
pub trait Other { fn added(&self); }
impl Other for Missing { fn added(&self) {} }
pub trait Defaulted { fn defaulted(&self) {} }
impl Defaulted for Missing {}
pub trait Changed { fn changed(&self, x: u64); }
impl Changed for Missing { fn changed(&self, x: u32) {} }
impl Changed for Complete { fn changed(&self, x: u64) {} }
pub trait Blanket { fn blanket(&self); }
impl<T: Copy> Blanket for T {}
pub struct Container<T>(T);
impl<T> Blanket for Container<T> {}
pub mod a { pub trait Same { fn scoped(&self); } pub struct A; impl Same for A {} }
pub mod b { pub trait Same {} pub struct B; impl Same for B {} }
