use renamed::Service;
pub struct Local;
impl
    Service for Local {}
pub struct Unrelated;
impl other::Service for Unrelated {}
