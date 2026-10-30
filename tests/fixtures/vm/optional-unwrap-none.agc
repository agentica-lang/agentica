# unwrap! on none halts with RUNTIME-UNWRAP-NONE at the receiver.
def lookup(key: String) -> Optional[Int]
  if key == "one"
    return some(1)
  end
  return none
end

def main() -> Void
  puts(lookup("one").unwrap!)
  puts(lookup("two").unwrap!)
  puts("not reached")
end
