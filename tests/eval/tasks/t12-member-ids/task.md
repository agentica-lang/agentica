# Task: change the type of the ids

`start.agc` (or `start.py` for Python) is a small library program that works. It reads commands from standard input until EOF (blank lines are ignored) and tracks members, books and loans. Ids are integers today: `member 7 ana`, `book 3 2 Dune`, `borrow 7 3`. Change the ids to strings, and save the result as `solution.agc` (or `solution.py`). The id type changes in the structs, the maps and lists that hold ids, the parsing, the comparisons, the sorting and every message that prints an id. Keep every other behavior as it is.

The commands (words are separated by single spaces):

- `member ID NAME`: add a member (an existing id is replaced and its loans are cleared).
- `book ID COPIES TITLE...`: add a book with `COPIES` copies (an integer of 1 or more). The title is all the remaining words, joined by single spaces.
- `borrow MEMBER BOOK` and `return MEMBER BOOK`.
- `loans MEMBER`: the member's loans, sorted by book id.
- `status`: every book sorted by id, as `ID TITLE: AVAILABLE/COPIES`.

## The new ids

- A member id is `M-` followed by one or more digits, for example `M-007` or `M-12`. A book id is `B-` followed by one or more digits, for example `B-003` or `B-10`. An id is a string, and two ids are equal only when they are the same text: `M-7` and `M-007` are different members.
- Ids are sorted as text, so `B-10` comes before `B-9`.
- An id of the wrong form (`7`, `m-7`, `M-`, `M-1x`, `B-3` where a member is expected) prints `error: invalid member id X` or `error: invalid book id X`, where `X` is the text as given. This replaces the old `error: bad command` for ids that are not integers.
- The checks go in this order: the number of arguments (`error: bad command` when it is wrong), then the member id, then the book id, then the rest of the arguments (for `book`, a `COPIES` that is not an integer of 1 or more is `error: bad command`), and only then the lookups (`error: unknown member ID`, `error: unknown book ID`, and the borrow and return errors).
- Every message prints ids as the strings: `member M-007: ana`, `book B-003: Dune (2)`, `error: unknown member M-009`, `B-003 Dune: 1/2`, and the loan lines `  B-003 Dune`.

Example input:

```text
member M-007 ana
book B-10 1 Emma Woods
book B-9 1 Zen
borrow M-007 B-9
borrow M-007 B-10
borrow 7 B-9
loans M-007
```

Example output:

```text
member M-007: ana
book B-10: Emma Woods (1)
book B-9: Zen (1)
ana borrowed Zen
ana borrowed Emma Woods
error: invalid member id 7
ana:
  B-10 Emma Woods
  B-9 Zen
```

Test it with your own input before you finish.
