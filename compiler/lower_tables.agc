## The tables of the lowering that are plain data: the builtins the VM implements, the operator instructions, and the
## builtin structs the VM can build. tests/test_frontend_lower.py compares VM_BUILTINS with a frozen copy.

## The `implementation` names of the builtins the VM has. A call of any other builtin is LOWER-UNSUPPORTED.
export VM_BUILTINS = Set.new([
  "puts", "IO.print", "IO.warn", "IO.inspect", "IO.gets", "IO.gets!", "IO.read", "IO.read_bytes", "IO.flush",
  "IO.eof?", "System.args", "System.exit", "System.env", "System.os", "System.pid", "String.from_int",
  "String.from_float", "ok", "error", "Result.ok?", "Result.unwrap!", "Result.unwrap_or", "Result.message",
  "List.map", "List.filter",
  "List.reduce", "List.each", "List.any?", "List.all?", "List.sort_by", "Range.size", "Range.to_a", "Range.include?",
  "Range.each", "Range.first", "Range.last", "Int.times", "Int.upto", "Int.downto", "List.size", "List.append",
  "List.set", "List.repeat", "List.concat", "List.take", "List.drop", "List.at", "List.reverse", "List.sort",
  "Map.has_key?", "Map.keys", "Map.size", "Map.put", "Map.get", "Map.delete", "Map.values", "Set.new", "Set.add",
  "Set.delete", "Set.include?", "Set.size", "Set.empty?", "Set.to_a", "Set.union", "Set.intersection",
  "Set.difference", "Set.subset?", "String.length", "String.upcase", "String.downcase", "String.trim", "String.split",
  "String.join", "String.contains?", "String.starts_with?", "String.ends_with?", "String.replace", "String.slice",
  "String.index_of", "String.at", "String.reverse", "String.code", "String.from_code", "String.from_bytes",
  "String.to_int", "String.to_int!", "String.to_float", "String.to_float!", "Float.from_int", "Float.to_int",
  "Float.to_int!", "Int.bit_and", "Int.bit_or", "Int.bit_xor", "Int.bit_not", "Int.shift_left", "Int.shift_right",
  "Int.shift_right_unsigned", "Float.to_bits", "Float.from_bits", "Float.to_bits32", "Float.from_bits32",
  "Time.now_ms", "Time.monotonic_ms", "Time.monotonic_ns", "Random.int", "Random.float", "JSON.parse", "JSON.encode",
  "JSON.from", "JSON.object", "JSON.array", "JSON.null", "JSON.null?", "JSON.get", "JSON.at", "JSON.string",
  "JSON.int", "JSON.float", "JSON.bool", "JSON.list", "JSON.decode", "JSON.schema", "File.open", "File.read_bytes",
  "File.read_line", "File.write", "File.write_bytes", "File.flush", "File.close", "File.each_line", "File.read_text",
  "File.write_text", "File.append_text", "File.stat", "File.lstat", "File.try_lock", "Dir.list", "Dir.mkdir",
  "Dir.mkdir_private", "Path.cwd", "Path.join", "Path.resolve", "Path.real", "Path.remove", "Path.rename",
  "Task.spawn", "Task.spawn_owning", "Task.await", "Task.sleep", "Channel.new", "Channel.send", "Channel.recv",
  "Channel.close", "Channel.closed?", "Process.spawn", "Process.send", "Process.send_bytes", "Process.read_line",
  "Process.read_bytes", "Process.close_stdin", "Process.wait", "Process.close", "TCP.connect", "TCP.listen",
  "TCP.accept", "TCP.local_port", "TCP.close_listener", "TCP.send", "TCP.send_bytes", "TCP.recv_bytes",
  "TCP.read_line", "TCP.close", "TLS.connect", "TLS.listen", "HttpWire.service", "HttpWire.awaited?", "HttpWire.jobs",
  "HttpWire.options", "HttpWire.clean_eof?", "HttpWire.connect_tls", "HttpWire.drop_tls", "HttpWire.chunked",
  "HttpWire.chunk", "HttpWire.chunk_read",
  "HttpWire.text", "HttpWire.read_head", "HttpWire.read_response", "HttpWire.read_text", "HttpWire.encode_request",
  "HttpWire.encode_response", "HttpWire.error_answer", "HttpWire.close_write", "HttpWire.server", "HttpWire.accept",
  "HttpWire.spawn", "HttpWire.close_server", "HttpWire.wait", "HttpWire.local_port",
  "LogRegistry.level", "LogRegistry.floor", "LogRegistry.set_level", "LogRegistry.lowest",
  "LogRegistry.install_default", "LogRegistry.attach", "LogRegistry.detach", "LogRegistry.names",
  "LogRegistry.handlers", "LogRegistry.task_id",
  "Process.spawn_captured", "Process.output", "Task.pending_count", "Process.spawn_channel",
  "Process.channel_read_line", "Process.channel_send", "Process.channel_close", "Process.read_available",
  "Process.parent_read_line", "Process.parent_send", "Task.await_result", "Task.unobserved_crash", "Test.test",
  "Test.run", "Test.eq", "Test.ok?", "Test.error?", "Test.assert", "FrontEnd.hand_off", "FrontEnd.std_source",
  "Task.map", "Task.cancel", "String.compare", "__fail_arg", "__lazy_channel", "__lazy_chunk_while", "__lazy_count",
  "__lazy_each", "__lazy_file", "__lazy_find", "__lazy_flat_map", "__lazy_group", "__lazy_list", "__lazy_map",
  "__lazy_produce", "__lazy_range", "__lazy_reduce", "__lazy_test", "__lazy_to_a", "__lazy_with_index",
  "__lazy_write_lines",
])

## The instruction of an operator on two Ints, by the token kind of the operator. `>` and `>=` use the instruction of
## `<` and `<=` with the operands swapped.
export INT_OPS: Map[String, String] = {
  "plus": "add-i", "minus": "sub-i", "multiply": "mul-i", "divide": "div-i", "modulo": "mod-i",
  "less": "lt-i", "less-equal": "le-i", "greater": "lt-i", "greater-equal": "le-i"
}

## The operators on two Strings: only `+`.
export STRING_OPS: Map[String, String] = {"plus": "concat"}

## The same for two Floats.
export FLOAT_OPS: Map[String, String] = {
  "plus": "add-f", "minus": "sub-f", "multiply": "mul-f", "divide": "div-f",
  "less": "lt-f", "less-equal": "le-f", "greater": "lt-f", "greater-equal": "le-f"
}

## The builtin records the VM can build as structs, in the order the struct table lists the ones a program uses.
export BUILTIN_STRUCTS = [
  "FileInfo", "Header", "HttpRequest", "HttpResponse", "HttpClientOptions", "HttpServerOptions", "ProcessOutput",
  "LogEvent", "HttpWire.Head", "HttpWire.Chunk", "HttpWire.Text", "HttpWire.Reply", "HttpWire.Job",
  "HttpWire.Response"
]

## The builtin structs that another one has a field of: using the key also puts these in the table.
export STRUCT_NEEDS: Map[String, List[String]] = {
  "HttpResponse": ["Header"], "HttpRequest": ["Header"], "HttpWire.Head": ["Header"],
  "HttpWire.Job": ["HttpResponse", "Header"], "HttpWire.Response": ["Header"]
}

## The most items one `list` instruction gathers and the most entries one `map` instruction gathers; larger literals
## are built in chunks.
export MAX_CHUNK = 255

## The smallest and largest Int, and the digits of the first (a literal `9223372036854775808` is the digits of an Int
## that does not fit).
export INT_MIN = -9223372036854775807 - 1
export INT_MAX = 9223372036854775807
export INT_MIN_DIGITS = "9223372036854775808"
