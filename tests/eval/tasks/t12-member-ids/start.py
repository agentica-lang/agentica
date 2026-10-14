import sys
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Book:
    id: int
    title: str
    copies: int


@dataclass(frozen=True)
class Member:
    id: int
    name: str


@dataclass(frozen=True)
class Library:
    books: dict[int, Book]
    members: dict[int, Member]
    loans: dict[int, list[int]]


def new_library() -> Library:
    return Library(books={}, members={}, loans={})


def bad_command() -> None:
    print("error: bad command")


def parse_int(text: str) -> int | None:
    try:
        return int(text)
    except ValueError:
        return None


def on_loan(lib: Library, book_id: int) -> int:
    return sum(1 for books in lib.loans.values() if book_id in books)


def member_command(lib: Library, args: list[str]) -> Library:
    if len(args) != 2:
        bad_command()
        return lib
    member_id = parse_int(args[0])
    if member_id is None:
        bad_command()
        return lib
    member = Member(id=member_id, name=args[1])
    print(f"member {member.id}: {member.name}")
    return replace(
        lib,
        members={**lib.members, member.id: member},
        loans={**lib.loans, member.id: []},
    )


def book_command(lib: Library, args: list[str]) -> Library:
    if len(args) < 3:
        bad_command()
        return lib
    book_id = parse_int(args[0])
    copies = parse_int(args[1])
    if book_id is None or copies is None or copies < 1:
        bad_command()
        return lib
    book = Book(id=book_id, title=" ".join(args[2:]), copies=copies)
    print(f"book {book.id}: {book.title} ({book.copies})")
    return replace(lib, books={**lib.books, book.id: book})


def borrow_command(lib: Library, args: list[str]) -> Library:
    if len(args) != 2:
        bad_command()
        return lib
    mid = parse_int(args[0])
    bid = parse_int(args[1])
    if mid is None or bid is None:
        bad_command()
        return lib
    if mid not in lib.members:
        print(f"error: unknown member {mid}")
        return lib
    if bid not in lib.books:
        print(f"error: unknown book {bid}")
        return lib
    book = lib.books[bid]
    if bid in lib.loans[mid]:
        print("error: already borrowed")
        return lib
    if on_loan(lib, bid) >= book.copies:
        print("error: no copies left")
        return lib
    print(f"{lib.members[mid].name} borrowed {book.title}")
    return replace(lib, loans={**lib.loans, mid: [*lib.loans[mid], bid]})


def return_command(lib: Library, args: list[str]) -> Library:
    if len(args) != 2:
        bad_command()
        return lib
    mid = parse_int(args[0])
    bid = parse_int(args[1])
    if mid is None or bid is None:
        bad_command()
        return lib
    if mid not in lib.members:
        print(f"error: unknown member {mid}")
        return lib
    if bid not in lib.books:
        print(f"error: unknown book {bid}")
        return lib
    if bid not in lib.loans[mid]:
        print("error: not borrowed")
        return lib
    kept = [b for b in lib.loans[mid] if b != bid]
    print(f"{lib.members[mid].name} returned {lib.books[bid].title}")
    return replace(lib, loans={**lib.loans, mid: kept})


def loans_command(lib: Library, args: list[str]) -> None:
    if len(args) != 1:
        bad_command()
        return
    mid = parse_int(args[0])
    if mid is None:
        bad_command()
        return
    if mid not in lib.members:
        print(f"error: unknown member {mid}")
        return
    member = lib.members[mid]
    ids = sorted(lib.loans[mid])
    if len(ids) == 0:
        print(f"{member.name} has no loans")
        return
    print(f"{member.name}:")
    for bid in ids:
        print(f"  {bid} {lib.books[bid].title}")


def status_command(lib: Library) -> None:
    for bid in sorted(lib.books):
        book = lib.books[bid]
        print(f"{book.id} {book.title}: {book.copies - on_loan(lib, bid)}/{book.copies}")


def run_command(lib: Library, line: str) -> Library:
    parts = [w for w in line.split(" ") if w != ""]
    args = parts[1:]
    match parts[0]:
        case "member":
            return member_command(lib, args)
        case "book":
            return book_command(lib, args)
        case "borrow":
            return borrow_command(lib, args)
        case "return":
            return return_command(lib, args)
        case "loans":
            loans_command(lib, args)
        case "status":
            status_command(lib)
        case _:
            bad_command()
    return lib


def main() -> None:
    lib = new_library()
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        lib = run_command(lib, line)


if __name__ == "__main__":
    main()
