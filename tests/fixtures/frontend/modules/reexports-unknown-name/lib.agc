export struct Address
  host: String
end

export enum Option
  Some(Int)
  None
end

export def parse(text: String) -> Address
  return Address(host: text)
end
