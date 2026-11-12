def main() -> Void
  puts("kitten".edit_distance("sitting"))
  puts("kitten".edit_distance("sitting", 2))
  puts("kitten".edit_distance("sitting", 3))
  puts("".edit_distance("abc"))
  puts("café".edit_distance("cafe"))
  puts("😀a".edit_distance("a😀", 0))
  puts("martha".jaro_winkler("marhta"))
  puts("dwayne".jaro_winkler("duane"))
  puts("".jaro_winkler(""))
  puts("abc".jaro_winkler("xyz"))
end
