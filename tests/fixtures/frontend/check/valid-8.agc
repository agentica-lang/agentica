def main() -> Void
  _a: Int = String.length("hola")
  _b: String = String.upcase(" x ".strip)
  c: List[String] = String.split("a,b", ",")
  _d: String = c.join("-")
  _e: Bool = "hola".include?("ol")
  _f: Bool = "hola".start_with?("ho")
  _g: Bool = "hola".end_with?("la")
  _h: String = String.replace("aXb", "X", "-")
  _i: String = String.slice("hola", 1, 2)
  _j: String = 3.to_s + 1.5.to_s
  _k: Int = "3".to_i!
  _l: Float = "1.5".to_f!
end

