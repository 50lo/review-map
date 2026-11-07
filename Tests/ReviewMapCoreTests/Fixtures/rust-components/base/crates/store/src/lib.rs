pub struct Store;
pub fn value() -> i32 { 1 }
#[cfg(test)]
mod tests {
    #[test]
    fn checks_value() { assert_eq!(super::value(), 1); }
}
