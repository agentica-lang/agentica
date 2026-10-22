---
title: SQLite
weight: 2
description: A real library, SQLite through an extern block, with safe functions that return Result.
---

## A real library: SQLite

The raw `extern` layer stays private, and safe functions on top of it return `Result`. It uses resources and `out` parameters ([Types and resources](/library/io-and-system/native/types/)). This program opens an in-memory database, fills a table and reads it back. It names the Linux library, `libsqlite3.so.0`; on macOS the system one is `libsqlite3.dylib`, and on Windows, give the name or absolute path of a SQLite DLL.

```agentica {mode="check"}
SQLITE_OK = 0
SQLITE_ROW = 100
SQLITE_DONE = 101

extern "libsqlite3.so.0"
  resource Db, free: sqlite3_close_v2
  resource Stmt, free: sqlite3_finalize
  def sqlite3_open(filename: C.String, out db: Db) -> C.Int
  def sqlite3_errstr(code: C.Int) -> C.String
  def sqlite3_errmsg(db: Db) -> C.String
  def sqlite3_prepare_v2(db: Db, sql: C.String, bytes: C.Int, out stmt: Stmt, out tail: C.Pointer) -> C.Int
  compute def sqlite3_step(stmt: Stmt) -> C.Int
  def sqlite3_column_int(stmt: Stmt, col: C.Int) -> C.Int
  def sqlite3_column_text(stmt: Stmt, col: C.Int) -> C.String
end

## Opens a database. A failed open may still give a handle, which is closed here.
def open(path: String) -> Result[Db]
  opened = sqlite3_open(path)
  if opened.result != SQLITE_OK
    Native.close(opened.db)
    return error("sqlite: #{sqlite3_errstr(opened.result)}")
  end
  return ok(opened.db)
end

## Prepares one statement, or gives SQLite's message.
def prepare(db: Db, sql: String) -> Result[Stmt]
  prepared = sqlite3_prepare_v2(db, sql, -1)
  if prepared.result != SQLITE_OK
    return error("sqlite: #{sqlite3_errmsg(db)}")
  end
  return ok(prepared.stmt)
end

## Runs a statement that returns no rows.
def run(db: Db, sql: String) -> Result[Void]
  stmt = try prepare(db, sql)
  if sqlite3_step(stmt) != SQLITE_DONE
    message = sqlite3_errmsg(db)
    Native.close(stmt)
    return error("sqlite: #{message}")
  end
  Native.close(stmt)
  return ok()
end

def main() -> Void
  db = open(":memory:").unwrap!
  run(db, "create table langs (id integer, name text)").unwrap!
  run(db, "insert into langs values (1, 'Ruby'), (2, 'Agentica')").unwrap!
  query = prepare(db, "select id, name from langs order by id").unwrap!
  while sqlite3_step(query) == SQLITE_ROW
    puts("#{sqlite3_column_int(query, 0)} #{sqlite3_column_text(query, 1)}")
  end
  Native.close(query)
  IO.inspect(prepare(db, "select from nowhere"))   # error("sqlite: near \"from\": syntax error")
  IO.inspect(open("/no/such/dir/x.db"))            # error("sqlite: unable to open database file")
  Native.close(db)
end
```
