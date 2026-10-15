export struct Box
  label: String
end

export def make(text: String) -> Box
  return Box(label: text)
end

