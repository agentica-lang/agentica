struct Book
  id: String
  title: String
  copies: Int
end

struct Member
  id: String
  name: String
end

struct Library
  books: Map[String, Book]
  members: Map[String, Member]
  loans: Map[String, List[String]]
end

def new_library() -> Library
  books: Map[String, Book] = {}
  members: Map[String, Member] = {}
  loans: Map[String, List[String]] = {}
  return Library(books: books, members: members, loans: loans)
end

def bad_command() -> Void
  puts("error: bad command")
end

def valid_id(text: String, prefix: String) -> Bool
  if !text.starts_with?(prefix) || text.length <= 2
    return false
  end
  digits = text.slice(2, text.length - 2)
  for i in 0...digits.length
    code = String.code(digits.at(i))
    if code < 48 || code > 57
      return false
    end
  end
  return true
end

def on_loan(lib: Library, book_id: String) -> Int
  count = 0
  for member_id in lib.loans.keys
    if lib.loans[member_id].any? do |b| b == book_id end
      count += 1
    end
  end
  return count
end

def member_command(lib: Library, args: List[String]) -> Library
  if args.size != 2
    bad_command()
    return lib
  end
  id = args[0]
  if !valid_id(id, "M-")
    puts("error: invalid member id #{id}")
    return lib
  end
  member = Member(id: id, name: args[1])
  puts("member #{member.id}: #{member.name}")
  empty: List[String] = []
  return Library(books: lib.books, members: lib.members.put(member.id, member), loans: lib.loans.put(member.id, empty))
end

def book_command(lib: Library, args: List[String]) -> Library
  if args.size < 3
    bad_command()
    return lib
  end
  id = args[0]
  if !valid_id(id, "B-")
    puts("error: invalid book id #{id}")
    return lib
  end
  copies = args[1].to_i
  if !copies.ok? || copies.unwrap! < 1
    bad_command()
    return lib
  end
  title = args.drop(2).join(" ")
  book = Book(id: id, title: title, copies: copies.unwrap!)
  puts("book #{book.id}: #{book.title} (#{book.copies})")
  return Library(books: lib.books.put(book.id, book), members: lib.members, loans: lib.loans)
end

def borrow_command(lib: Library, args: List[String]) -> Library
  if args.size != 2
    bad_command()
    return lib
  end
  mid = args[0]
  bid = args[1]
  if !valid_id(mid, "M-")
    puts("error: invalid member id #{mid}")
    return lib
  end
  if !valid_id(bid, "B-")
    puts("error: invalid book id #{bid}")
    return lib
  end
  if !lib.members.has_key?(mid)
    puts("error: unknown member #{mid}")
    return lib
  end
  if !lib.books.has_key?(bid)
    puts("error: unknown book #{bid}")
    return lib
  end
  book = lib.books[bid]
  if lib.loans[mid].any? do |b| b == bid end
    puts("error: already borrowed")
    return lib
  end
  if on_loan(lib, bid) >= book.copies
    puts("error: no copies left")
    return lib
  end
  puts("#{lib.members[mid].name} borrowed #{book.title}")
  return Library(books: lib.books, members: lib.members, loans: lib.loans.put(mid, lib.loans[mid].push(bid)))
end

def return_command(lib: Library, args: List[String]) -> Library
  if args.size != 2
    bad_command()
    return lib
  end
  mid = args[0]
  bid = args[1]
  if !valid_id(mid, "M-")
    puts("error: invalid member id #{mid}")
    return lib
  end
  if !valid_id(bid, "B-")
    puts("error: invalid book id #{bid}")
    return lib
  end
  if !lib.members.has_key?(mid)
    puts("error: unknown member #{mid}")
    return lib
  end
  if !lib.books.has_key?(bid)
    puts("error: unknown book #{bid}")
    return lib
  end
  if !(lib.loans[mid].any? do |b| b == bid end)
    puts("error: not borrowed")
    return lib
  end
  kept = lib.loans[mid].filter do |b| b != bid end
  puts("#{lib.members[mid].name} returned #{lib.books[bid].title}")
  return Library(books: lib.books, members: lib.members, loans: lib.loans.put(mid, kept))
end

def loans_command(lib: Library, args: List[String]) -> Void
  if args.size != 1
    bad_command()
    return
  end
  mid = args[0]
  if !valid_id(mid, "M-")
    puts("error: invalid member id #{mid}")
    return
  end
  if !lib.members.has_key?(mid)
    puts("error: unknown member #{mid}")
    return
  end
  member = lib.members[mid]
  ids = lib.loans[mid].sort
  if ids.size == 0
    puts("#{member.name} has no loans")
    return
  end
  puts("#{member.name}:")
  for bid in ids
    puts("  #{bid} #{lib.books[bid].title}")
  end
end

def status_command(lib: Library) -> Void
  for bid in lib.books.keys.sort
    book = lib.books[bid]
    puts("#{book.id} #{book.title}: #{book.copies - on_loan(lib, bid)}/#{book.copies}")
  end
end

def run_command(lib: Library, line: String) -> Library
  parts = line.split(" ").filter do |w| w != "" end
  args = parts.drop(1)
  case parts[0]
    "member" -> return member_command(lib, args)
    "book" -> return book_command(lib, args)
    "borrow" -> return borrow_command(lib, args)
    "return" -> return return_command(lib, args)
    "loans" -> loans_command(lib, args)
    "status" -> status_command(lib)
    _ -> bad_command()
  end
  return lib
end

def main() -> Void
  lib = new_library()
  while !IO.eof?()
    line = IO.gets!().strip
    if line == ""
      next
    end
    lib = run_command(lib, line)
  end
end
