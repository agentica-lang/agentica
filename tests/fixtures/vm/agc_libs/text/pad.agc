export def left(text: String, width: Int) -> String
  if text.length >= width
    return text
  end
  return left(" " + text, width)
end
