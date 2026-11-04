def main() -> Void
  _a: Int = String.length("hola")
  _b: String = String.upcase(String.trim(" x "))
  c: List[String] = String.split("a,b", ",")
  _d: String = String.join(c, "-")
  _e: Bool = String.contains?("hola", "ol")
  _f: Bool = String.starts_with?("hola", "ho")
  _g: Bool = String.ends_with?("hola", "la")
  _h: String = String.replace("aXb", "X", "-")
  _i: String = String.slice("hola", 1, 2)
  _j: String = String.from_int(3) + String.from_float(1.5)
  _k: Int = String.to_int!("3")
  _l: Float = String.to_float!("1.5")
end

