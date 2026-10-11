def main() -> Void
  j = Result.unwrap!(JSON.parse("{\"a\": 1}"))
  puts(JSON.int(Result.unwrap!(JSON.get(j, "a"))))
  puts(Result.unwrap!(JSON.get(j, "b")))
end
