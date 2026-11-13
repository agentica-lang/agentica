struct Box
  label: String
end

def make(text: String) -> Box
  return Box(label: text)
end
