# String#slice and String#at on ASCII, mixed and multi-byte strings: runs of ASCII long
# enough to be crossed a word at a time, multi-byte characters at both ends, slices that
# run to the end, and every start and length checked against the characters one by one.
def by_chars(chars: List[String], start: Int, length: Int) -> String
  return chars.drop(start).take(length).join("")
end

def mismatches(text: String) -> Int
  chars = text.split("")
  n = text.length
  bad = 0
  start = 0
  while start <= n
    length = 0
    while start + length <= n
      if text.slice(start, length) != by_chars(chars, start, length)
        bad += 1
      end
      length += 1
    end
    if start < n && text.at(start) != chars[start]
      bad += 1
    end
    start += 1
  end
  return bad
end

def main() -> Void
  ascii = "plain ASCII text, long enough to cross words"
  mixed = "é#{ascii}ü — #{ascii}😀"
  wide = "😀é€😀é€😀é€😀"
  page = ("<p>crème brûlée #{ascii}</p>\n" * 40) + "fin ✓"
  puts([ascii.length, mixed.length, wide.length, page.length, page.bytesize].inspect)
  puts([mismatches(""), mismatches(ascii), mismatches(mixed), mismatches(wide)].inspect)
  puts(mismatches(page.slice(page.length - 90, 90)))
  n = page.length
  puts(page.slice(36, n - 36).length)
  puts(page.slice(n - 7, 7).inspect)
  puts(page.slice(n - 1, 1).inspect)
  puts(page.slice(n, 0).inspect)
  puts(page.slice(3, 12).inspect)
  puts(page.slice(n - 30, 12).inspect)
  puts(page.slice(0, n) == page)
  puts(mixed.slice(0, 1) + mixed.slice(mixed.length - 1, 1))
  puts(page.at(n - 1) + page.at(n - 3) + page.at(4))
  puts(mixed.slice(-1, 1).inspect)
end
