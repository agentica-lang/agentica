# A seed of make vm-libfuzz-run: every function of the agentica_fuzz module that the fuzz driver registers (vm/fuzz.c),
# so a mutant reaches the native signature parser (the type blocks and the canonical types) and each getter and
# constructor of a module call. make vm-libfuzz-run checks that it runs to its end through the driver.
struct Pair
  left: Int
  right: Int
end

enum Tag
  Empty
  Text(String)
end

enum Count
  Empty
  One(Int)
  Two(Int, Int)
end

extern module "agentica_fuzz"
  def lengths(words: List[String]) -> List[Int]
  def keys(first: Map[String, Int], second: Map[String, Int]) -> Result[List[List[String]]]
  def bytes(data: Optional[Bytes]) -> Optional[Bytes]
  def swap(pair: Pair) -> Pair
  def retag(tag: Tag) -> Tag
  def step(count: Count) -> Count
end

def main() -> Void
  puts(lengths(["a", "bc", ""]))
  puts(keys({"x": 1, "y": 2}, {}))
  puts(keys({}, {"z": 3}))
  puts(bytes(some("abc".bytes)))
  puts(bytes(none))
  puts(swap(Pair(left: 1, right: 2)))
  puts(retag(Tag.Empty))
  puts(retag(Tag.Text("x")))
  puts(step(step(step(Count.Empty))))
end
