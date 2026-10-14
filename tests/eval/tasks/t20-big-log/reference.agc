def digits?(text: String) -> Bool
  if text == ""
    return false
  end
  for i in 0...text.length
    code = String.code(text.at(i))
    if code < 48 || code > 57
      return false
    end
  end
  return true
end

def report(line: String) -> Result[Void]
  parts = line.split(" ")
  if parts.size != 6 || !digits?(parts[0]) || !digits?(parts[4]) || !digits?(parts[5])
    return ok()
  end
  if parts[1] == "" || parts[2] == "" || parts[3] == ""
    return ok()
  end
  if parts[4].to_i! >= 500 && parts[5].to_i! >= 800
    puts("#{parts[0]} #{parts[1]} #{parts[5]}")
  end
  return ok()
end

def main() -> Void
  result = File.each_line(System.args()[0], 65536, 10000, &report)
  if !result.ok?
    IO.warn(result.message)
    System.exit(1)
  end
end
