import Coverage from "std/test/coverage"

# The merge of `agentica test --coverage`, for the tests: `read FILE` prints the LCOV of FILE as the merge writes it
# back, and `collect FOLDER` merges the parts of FOLDER into coverage/lcov.info and prints the `coverage` object of
# `--json`.
def main() -> Void
  words = System.args()
  if words[0] == "read"
    sources = Coverage.parse(File.read_text(words[1], 5000).unwrap!).unwrap!
    print(Coverage.text(Coverage.add({}, sources), []))
  else
    puts(JSON.encode(Coverage.json(Coverage.collect(words[1], []))))
  end
end
