def label(n: Int) -> String
  return "n=#{twice(n)}"
end

private

def twice(n: Int) -> Int
  return n * 2
end
