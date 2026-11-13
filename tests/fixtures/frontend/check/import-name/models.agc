def make() -> Secret
  return Secret(value: 1)
end

private

struct Secret
  value: Int
end
