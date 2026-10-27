# A full DuckDB flow through the C API, in one teaching-sized program: check the
# library version, open :memory: and connect, set small resource limits, make a
# typed table, read INTEGER, BIGINT, DOUBLE, VARCHAR and NULL rows back in
# order, catch one SQL error and keep going, then COPY the table to CSV and to
# Parquet and read both files back with their counts and typed rows compared.
#
# The extern block stays private in this file; main.agc only calls run_demo.
# The database and the connection are resources: duckdb_close and
# duckdb_disconnect take the address of the handle, so the resources name them
# with free_address:. The helpers close each one on every normal path, and the
# end of the owning task (a cancel or an error included) closes what is left.
# See README.md.
VERSION_WANT = "v2.0.0"
STATE_OK = 0
TYPE_INTEGER = 4
TYPE_BIGINT = 5
TYPE_DOUBLE = 11
TYPE_VARCHAR = 17
IO_TIMEOUT_MS = 5000
WANT_ROWS = [
  "1|10000000000|9.5|Ada",
  "2|-42|-0.25|Böb \"Jr\"",
  "3|0|NULL|NULL",
  "4|7|3.125|O'Brien"
]

struct PersonRow
  id: Int
  code: Int
  score: Float
  has_score: Bool
  name: String
  has_name: Bool
end

struct PeopleRead
  columns: Int
  lines: List[String]
end

# The C signatures below are copied from the pinned header
# (duckdb v2.0.0, src/include/duckdb.h): idx_t is 64 bits, so the counts read
# through C.Int64, which holds every small count of this demo. duckdb_open and
# duckdb_connect write the new handle to an out resource, which is closed
# already when C left it NULL. DuckdbResult is the duckdb_result that
# duckdb_query fills: the program only sizes its buffer with it
# (Native.size_of) and leaves the fields to the duckdb_* accessors.
extern "duckdb"
  resource Database, free_address: duckdb_close
  resource Connection, free_address: duckdb_disconnect

  struct DuckdbResult
    deprecated_column_count: C.Int64
    deprecated_row_count: C.Int64
    deprecated_rows_changed: C.Int64
    deprecated_columns: C.Pointer
    deprecated_error_message: C.Pointer
    internal_data: C.Pointer
  end

  def duckdb_library_version() -> C.String
  def duckdb_open(path: C.String, out db: Database) -> C.Int32
  def duckdb_connect(db: Database, out conn: Connection) -> C.Int32
  def duckdb_query(conn: Connection, sql: C.String, out_buf: C.Pointer) -> C.Int32
  def duckdb_destroy_result(buf: C.Pointer) -> Void
  def duckdb_result_error(buf: C.Pointer) -> C.Pointer
  def duckdb_free(at: C.Pointer) -> Void
  def duckdb_column_count(buf: C.Pointer) -> C.Int64
  def duckdb_column_type(buf: C.Pointer, col: C.Int64) -> C.Int32
  def duckdb_row_count(buf: C.Pointer) -> C.Int64
  def duckdb_rows_changed(buf: C.Pointer) -> C.Int64
  def duckdb_value_is_null(buf: C.Pointer, col: C.Int64, row: C.Int64) -> C.Bool
  def duckdb_value_int32(buf: C.Pointer, col: C.Int64, row: C.Int64) -> C.Int32
  def duckdb_value_int64(buf: C.Pointer, col: C.Int64, row: C.Int64) -> C.Int64
  def duckdb_value_double(buf: C.Pointer, col: C.Int64, row: C.Int64) -> C.Double
  def duckdb_value_varchar(buf: C.Pointer, col: C.Int64, row: C.Int64) -> C.Pointer
end

export def run_demo(out_dir: String) -> Result[Void]
  have = version()
  if have != VERSION_WANT
    return error("duckdb: want library #{VERSION_WANT}, have #{have}")
  end
  puts("duckdb #{have}")
  try prepare_dir(out_dir)
  csv_path = try Path.join([out_dir, "people.csv"])
  parquet_path = try Path.join([out_dir, "people.parquet"])
  try refuse_existing(csv_path)
  try refuse_existing(parquet_path)
  db_out = open_db(":memory:")
  if !db_out.ok?()
    return error(db_out.message())
  end
  db = db_out.unwrap!()
  done = run_all(db, csv_path, parquet_path)
  Native.close(db)
  return done
end

def version() -> String
  return duckdb_library_version()
end

def prepare_dir(out_dir: String) -> Result[Void]
  if Dir.list(out_dir, IO_TIMEOUT_MS).ok?()
    return error("duckdb: refusing to reuse existing #{out_dir}")
  end
  try Dir.mkdir_private(out_dir, IO_TIMEOUT_MS)
  return ok()
end

def refuse_existing(path: String) -> Result[Void]
  if File.stat(path, IO_TIMEOUT_MS).ok?()
    return error("duckdb: refusing to overwrite #{path}")
  end
  return ok()
end

def run_all(db: Database, csv_path: String, parquet_path: String) -> Result[Void]
  conn_out = connect_db(db)
  if !conn_out.ok?()
    return error(conn_out.message())
  end
  conn = conn_out.unwrap!()
  done = phases(conn, csv_path, parquet_path)
  Native.close(conn)
  return done
end

def phases(conn: Connection, csv_path: String, parquet_path: String) -> Result[Void]
  try setup(conn)
  try seed(conn)
  try show_people(conn)
  try show_error(conn)
  try csv_roundtrip(conn, csv_path)
  try parquet_roundtrip(conn, parquet_path)
  return ok()
end

def setup(conn: Connection) -> Result[Void]
  try exec_sql(conn, "SET threads TO 1")
  try exec_sql(conn, "SET memory_limit TO '128MiB'")
  try exec_sql(conn, "CREATE TABLE people(id INTEGER, code BIGINT, score DOUBLE, name VARCHAR)")
  return ok()
end

def seed(conn: Connection) -> Result[Void]
  out = query_buffer(conn, "INSERT INTO people VALUES (1, 10000000000, 9.5, 'Ada'), (2, -42, -0.25, 'Böb \"Jr\"'), (3, 0, NULL, NULL), (4, 7, 3.125, 'O''Brien')")
  if !out.ok?()
    return error(out.message())
  end
  buf = out.unwrap!()
  changed = duckdb_rows_changed(buf)
  close_result(buf)
  if changed != 4
    return error("duckdb: INSERT changed #{changed} rows, want 4")
  end
  return ok()
end

def show_people(conn: Connection) -> Result[Void]
  got = try fetch_people(conn, "SELECT id, code, score, name FROM people ORDER BY id")
  if got.lines.join("\n") != WANT_ROWS.join("\n")
    return error("duckdb: people rows differ: #{got.lines.join(" | ")}")
  end
  puts("columns: #{got.columns}")
  puts("rows: #{List.size(got.lines)}")
  got.lines.each do |line| puts(line) end
  return ok()
end

def show_error(conn: Connection) -> Result[Void]
  out = query_buffer(conn, "SELECT * FROM no_such_table_xyz")
  if out.ok?()
    close_result(out.unwrap!())
    return error("duckdb: the bogus query unexpectedly succeeded")
  end
  puts("error: #{List.first(String.split(out.message(), "\n"))}")
  return ok()
end

def csv_roundtrip(conn: Connection, csv_path: String) -> Result[Void]
  try exec_sql(conn, "COPY people TO #{sql_path(csv_path)} (HEADER)")
  try exec_sql(conn, "CREATE TABLE people_csv(id INTEGER, code BIGINT, score DOUBLE, name VARCHAR)")
  try exec_sql(conn, "COPY people_csv FROM #{sql_path(csv_path)} (HEADER)")
  try check_same(conn, "csv", "SELECT id, code, score, name FROM people_csv ORDER BY id")
  head = try File.read_text(csv_path, IO_TIMEOUT_MS)
  first = List.first(String.split(head, "\n"))
  if first != "id,code,score,name"
    return error("duckdb: csv header is #{first}")
  end
  puts("csv header: #{first}")
  return ok()
end

def parquet_roundtrip(conn: Connection, parquet_path: String) -> Result[Void]
  try exec_sql(conn, "COPY people TO #{sql_path(parquet_path)} (FORMAT PARQUET)")
  try exec_sql(conn, "CREATE TABLE people_parquet(id INTEGER, code BIGINT, score DOUBLE, name VARCHAR)")
  try exec_sql(conn, "COPY people_parquet FROM #{sql_path(parquet_path)}")
  try check_same(conn, "parquet", "SELECT id, code, score, name FROM people_parquet ORDER BY id")
  return ok()
end

def check_same(conn: Connection, label: String, sql: String) -> Result[Void]
  n = try scalar_count(conn, "SELECT COUNT(*) FROM #{label_table(label)}")
  if n != 4
    return error("duckdb: #{label} roundtrip has #{n} rows, want 4")
  end
  lines = try fetch_lines(conn, sql)
  if lines.join("\n") != WANT_ROWS.join("\n")
    return error("duckdb: #{label} roundtrip rows differ: #{lines.join(" | ")}")
  end
  puts("#{label} rows: #{n}")
  return ok()
end

def label_table(label: String) -> String
  if label == "csv"
    return "people_csv"
  end
  return "people_parquet"
end

def scalar_count(conn: Connection, sql: String) -> Result[Int]
  out = query_buffer(conn, sql)
  if !out.ok?()
    return error(out.message())
  end
  buf = out.unwrap!()
  if duckdb_column_count(buf) != 1 or duckdb_row_count(buf) != 1
    close_result(buf)
    return error("duckdb: scalar query has the wrong shape")
  end
  value = duckdb_value_int64(buf, 0, 0)
  close_result(buf)
  return ok(value)
end

def fetch_people(conn: Connection, sql: String) -> Result[PeopleRead]
  out = query_buffer(conn, sql)
  if !out.ok?()
    return error(out.message())
  end
  buf = out.unwrap!()
  rendered = render_people(buf)
  close_result(buf)
  return rendered
end

def fetch_lines(conn: Connection, sql: String) -> Result[List[String]]
  got = try fetch_people(conn, sql)
  return ok(got.lines)
end

def render_people(buf: C.Pointer) -> Result[PeopleRead]
  cols = duckdb_column_count(buf)
  if cols != 4
    return error("duckdb: want 4 columns, have #{cols}")
  end
  if duckdb_column_type(buf, 0) != TYPE_INTEGER
    return error("duckdb: column 0 is not INTEGER")
  end
  if duckdb_column_type(buf, 1) != TYPE_BIGINT
    return error("duckdb: column 1 is not BIGINT")
  end
  if duckdb_column_type(buf, 2) != TYPE_DOUBLE
    return error("duckdb: column 2 is not DOUBLE")
  end
  if duckdb_column_type(buf, 3) != TYPE_VARCHAR
    return error("duckdb: column 3 is not VARCHAR")
  end
  n = duckdb_row_count(buf)
  rows = (0...n).to_a.map do |i| row_text(read_person(buf, i)) end
  return ok(PeopleRead(columns: cols, lines: rows))
end

def read_person(buf: C.Pointer, row: Int) -> PersonRow
  id = duckdb_value_int32(buf, 0, row)
  code = duckdb_value_int64(buf, 1, row)
  has_score = !duckdb_value_is_null(buf, 2, row)
  score = 0.0
  if has_score
    score = duckdb_value_double(buf, 2, row)
  end
  has_name = !duckdb_value_is_null(buf, 3, row)
  name = ""
  if has_name
    name = read_text_cell(buf, 3, row)
  end
  return PersonRow(id: id, code: code, score: score, has_score: has_score, name: name, has_name: has_name)
end

def row_text(row: PersonRow) -> String
  score = "NULL"
  if row.has_score
    score = row.score.to_s()
  end
  name = "NULL"
  if row.has_name
    name = row.name
  end
  return "#{row.id}|#{row.code}|#{score}|#{name}"
end

# Quote a filesystem path for SQL: single quotes double, and the whole path
# sits in single quotes, so a backslash in a Windows path stays literal.
def sql_path(path: String) -> String
  return "'#{String.replace(path, "'", "''")}'"
end

# A failed open may still give a handle, which duckdb_close frees: close it
# before the error. A NULL handle is a closed resource, which close skips.
def open_db(path: String) -> Result[Database]
  opened = duckdb_open(path)
  if opened.result != STATE_OK or Native.closed?(opened.db)
    Native.close(opened.db)
    return error("duckdb_open(#{path}) failed")
  end
  return ok(opened.db)
end

def connect_db(db: Database) -> Result[Connection]
  connected = duckdb_connect(db)
  if connected.result != STATE_OK or Native.closed?(connected.conn)
    Native.close(connected.conn)
    return error("duckdb_connect failed")
  end
  return ok(connected.conn)
end

def exec_sql(conn: Connection, sql: String) -> Result[Void]
  out = query_buffer(conn, sql)
  if !out.ok?()
    return error(out.message())
  end
  close_result(out.unwrap!())
  return ok()
end

def query_buffer(conn: Connection, sql: String) -> Result[C.Pointer]
  buf = Native.memory_pointer(Native.size_of(DuckdbResult))
  state = duckdb_query(conn, sql, buf)
  if state != STATE_OK
    message = read_error(buf)
    duckdb_destroy_result(buf)
    Native.free(buf)
    return error(message)
  end
  return ok(buf)
end

def read_error(buf: C.Pointer) -> String
  at = duckdb_result_error(buf)
  if Native.null?(at)
    return "duckdb query failed"
  end
  return Native.get_string(at, 0)
end

def close_result(buf: C.Pointer) -> Void
  duckdb_destroy_result(buf)
  Native.free(buf)
end

# Copy an owned DuckDB string, then free the C original: get_string reads but
# never frees, and the pointer must not be lost through a C.String copy.
def read_text_cell(buf: C.Pointer, col: Int, row: Int) -> String
  at = duckdb_value_varchar(buf, col, row)
  if Native.null?(at)
    return "NULL"
  end
  text = Native.get_string(at, 0)
  duckdb_free(at)
  return text
end
