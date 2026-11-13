struct Address
  host: String
end

enum Option
  Some(Int)
  None
end

def parse(text: String) -> Address
  return Address(host: text)
end
