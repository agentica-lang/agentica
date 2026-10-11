def main() -> Void
  open = "["
  close = "]"
  keys = "{\"a\":"
  braces = "}"
  i = 0
  while i < 13
    open = open + open
    close = close + close
    if i < 12
      keys = keys + keys
      braces = braces + braces
    end
    i = i + 1
  end
  lists = open + "1" + close
  out = JSON.encode(Result.unwrap!(JSON.parse(lists)))
  puts(out.length)
  puts(out == lists)
  objects = keys + "[]" + braces
  puts(JSON.encode(Result.unwrap!(JSON.parse(objects))) == objects)
  puts(JSON.parse(open + close))
end
