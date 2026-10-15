def main() -> Void
  a: Int = String.length("hola")
  b: String = String.upcase(String.trim(" x "))
  c: List[String] = String.split("a,b", ",")
  d: String = String.join(c, "-")
  e: Bool = String.contains?("hola", "ol")
  f: Bool = String.starts_with?("hola", "ho")
  g: Bool = String.ends_with?("hola", "la")
  h: String = String.replace("aXb", "X", "-")
  i: String = String.slice("hola", 1, 2)
  j: String = String.from_int(3) + String.from_float(1.5)
  k: Int = String.to_int!("3")
  l: Float = String.to_float!("1.5")
end

