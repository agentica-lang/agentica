struct Secret
  value: Int
end

export def make() -> Secret
  return Secret(value: 1)
end
