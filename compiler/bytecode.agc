import Writer from "bytecode_writer"
import CheckText from "check_text"
import Checker from "checker"
import Env from "link_env"
import LinkText from "link_text"
import Linker from "linker"
import Lowering from "lowering"
import LowerText from "lower_text"

# `agentica compiler/bytecode.agc [flags] ROOT -o OUT ...` links, checks, lowers and writes each ROOT file to the .agcb
# file OUT, and prints `== ROOT`, then `wrote N bytes` or the ERROR line of the first failure (those of lower.agc, and
# BYTECODE- ones). No file is written for a failure. The flags are those of link.agc and apply to the roots after them:
# `--stdlib=DIR` (the default is stdlib), `--agentica-path=V`, `--xdg-data-home=V` and `--home=V`.
def main() -> Void
  stdlib = "stdlib"
  env = Env.process_env()
  root = ""
  output_next = false
  for argument in System.args()
    if output_next
      output_next = false
      puts("== " + root)
      puts(compile(root, argument, Env.settings(stdlib, env)))
    elsif argument == "-o"
      output_next = true
    elsif argument.starts_with?("--stdlib=")
      stdlib = argument.slice(9, argument.length - 9)
    elsif argument.starts_with?("--agentica-path=")
      env = env.with(agentica_path: argument.slice(16, argument.length - 16))
    elsif argument.starts_with?("--xdg-data-home=")
      env = env.with(xdg_data_home: argument.slice(16, argument.length - 16))
    elsif argument.starts_with?("--home=")
      env = env.with(home: argument.slice(7, argument.length - 7))
    else
      root = argument
    end
  end
end

# Compiles the file at path into the file at output, and says what happened in one line.
def compile(path: String, output: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return LinkText.failure_text(LinkText.root_dir_of(path), failure)
    Linker.Linking.Done(linked) -> return check(linked, output, settings)
  end
end

def check(linked: Linker.Linked, output: String, settings: Env.Settings) -> String
  case Checker.check(linked, settings.catalog)
    Checker.Checking.Failed(problem) -> return CheckText.problem_text(linked.root_dir, problem)
    Checker.Checking.Done(checked) -> return lower(linked, Lowering.lower(linked, checked, settings.catalog), output)
  end
end

def lower(linked: Linker.Linked, lowered: Lowering.Lowered, output: String) -> String
  case lowered
    Lowering.Lowered.Failed(problem) -> return LowerText.problem_text(linked.root_dir, problem)
    Lowering.Lowered.Done(program) -> return write(linked.root_dir, Writer.write(linked.root_dir, program), output)
  end
end

def write(root_dir: String, written: Writer.Written, output: String) -> String
  case written
    Writer.Written.Failed(problem) -> return LowerText.problem_text(root_dir, problem)
    Writer.Written.Done(bytes) ->
      saved = save(output, bytes)
      if saved.ok?
        return "wrote " + bytes.size.to_s + " bytes"
      end
      return "cannot write " + output + ": " + saved.message
  end
end

# Saves the bytes in pieces of 1 MiB, the most File.write_bytes takes.
def save(path: String, bytes: List[Int]) -> Result[Void]
  out = try File.open(path, "write", 60000)
  rest = bytes
  while rest.size > 0
    try File.write_bytes(out, rest.take(1048576), 60000)
    rest = rest.drop(1048576)
  end
  try File.close(out, 60000)
  return ok()
end
