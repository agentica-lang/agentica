# A front end for tests/test_single_binary.py, run as `agentica --front-end front.agcb WORDS...`. It calls the
# two FrontEnd builtins directly, so the test sees what the C side does with them.
#
#   inputs               prints the arguments the binary gave it, joined with spaces
#   std PATH             prints the std/ source at PATH of stdlib/, or the error
#   hand-off FILE.agcb [OPTIONS... -- ARGUMENTS...]
#                        hands the program in FILE to the VM with the options and the arguments
#   crash                stops with a runtime error, as the driver of `agentica test` could
#   bad-program          hands over a "program" with a byte that is not one
#   bad-word             hands over a program with an argument that has a character 0
#   too-many-options     hands over more options than the driver takes
#   too-many-arguments   hands over more arguments than the driver takes

def main() -> Void
  # The binary puts `--version V --self PATH [--embedded-bdd] --` before the words.
  words = System.args().drop(5)
  if words[0] == "--embedded-bdd"
    words = System.args().drop(6)
  elsif words[0] == "--"
    words = words.drop(1)
  end
  if words.size == 0
    System.exit(2)
  elsif words[0] == "inputs"
    puts(System.args().join(" "))
  elsif words[0] == "std"
    shown(FrontEnd.std_source(words[1]))
  elsif words[0] == "hand-off"
    hand_off(words[1], words.drop(2))
  elsif words[0] == "crash"
    puts(1 / (words.size - 1))
  elsif words[0] == "bad-program"
    shown_void(FrontEnd.hand_off([1, 300], [], []))
  elsif words[0] == "bad-word"
    shown_void(FrontEnd.hand_off([1], [], ["a#{String.from_code(0)}b"]))
  elsif words[0] == "too-many-options"
    shown_void(FrontEnd.hand_off([1], List.repeat("--allow-run", 65), []))
  elsif words[0] == "too-many-arguments"
    shown_void(FrontEnd.hand_off([1], [], List.repeat("a", 1048576).push("a")))
  end
end

def shown(result: Result[String]) -> Void
  if result.ok?
    IO.print(result.unwrap!)
  else
    puts("error: #{result.message}")
  end
end

def shown_void(result: Result[Void]) -> Void
  puts("error: #{result.message}")
end

def hand_off(file: String, rest: List[String]) -> Void
  options: List[String] = []
  arguments: List[String] = []
  in_arguments = false
  for word in rest
    if word == "--" and !in_arguments
      in_arguments = true
    elsif in_arguments
      arguments = arguments.push(word)
    else
      options = options.push(word)
    end
  end
  shown_void(FrontEnd.hand_off(program(file), options, arguments))
end

def program(file: String) -> List[Int]
  handle = File.open(file, "read", 5000).unwrap!
  bytes: List[Int] = []
  chunk = File.read_bytes(handle, 1048576, 5000).unwrap!
  while chunk.size > 0
    bytes = bytes.concat(chunk)
    chunk = File.read_bytes(handle, 1048576, 5000).unwrap!
  end
  File.close(handle, 5000)
  return bytes
end
