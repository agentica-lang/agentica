import Writer from "bytecode_writer"
import CheckText from "../check/check_text"
import Checker from "../check/checker"
import Host from "../io/host"
import Env from "../modules/link_env"
import LinkText from "../modules/link_text"
import Linker from "../modules/linker"
import Lowering from "../lower/lowering"
import LowerText from "../lower/lower_text"
import SaveFile from "../io/save_file"

# `agentica compiler/bytecode/bytecode.agc [flags] ROOT -o OUT ...` links, checks, lowers and writes each ROOT file to
# the .agcb file OUT, and prints `== ROOT`, then `wrote N bytes` or the ERROR line of the first failure (those of
# lower.agc, and BYTECODE- ones). No file is written for a failure. The flags are those of link.agc and apply to the
# roots after them: `--stdlib=DIR` (the default is stdlib), `--agentica-path=V`, `--xdg-data-home=V`, `--home=V`,
# `--local-app-data=V`; and `--version=V`, the Agentica version of the header, which a root needs (the front end gets
# it as an input, 35.3).
def main() -> Void
  stdlib = "stdlib"
  env = Host.process_env()
  version = ""
  root = ""
  output_next = false
  for argument in System.args()
    if output_next
      output_next = false
      puts("== #{root}")
      puts(compile(root, argument, Env.settings(Host.workspace(), stdlib, env).with(version: version)))
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
    elsif argument.starts_with?("--local-app-data=")
      env = env.with(local_app_data: argument.slice(17, argument.length - 17))
    elsif argument.starts_with?("--version=")
      version = argument.slice(10, argument.length - 10)
    else
      root = argument
    end
  end
end

# Compiles the file at path into the file at output, and says what happened in one line.
def compile(path: String, output: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return LinkText.root_failure_text(settings.workspace, path, failure)
    Linker.Linking.Done(linked) -> return check(linked, output, settings)
  end
end

def check(linked: Linker.Linked, output: String, settings: Env.Settings) -> String
  case Checker.check(linked, settings)
    Checker.Checking.Failed(problem) -> return CheckText.problem_text(settings.workspace, linked.root_dir, problem)
    Checker.Checking.Done(checked) ->
      lowered = Lowering.lower(linked, checked)
      return lower(linked, lowered, output, settings)
  end
end

def lower(linked: Linker.Linked, lowered: Lowering.Lowered, output: String, settings: Env.Settings) -> String
  case lowered
    Lowering.Lowered.Failed(problem) -> return LowerText.problem_text(settings.workspace, linked.root_dir, problem)
    Lowering.Lowered.Done(program) ->
      written = Writer.write(settings.workspace, linked.root_dir, program, settings.version)
      return write(linked.root_dir, written, output, settings)
  end
end

def write(root_dir: String, written: Writer.Written, output: String, settings: Env.Settings) -> String
  case written
    Writer.Written.Failed(problem) -> return LowerText.problem_text(settings.workspace, root_dir, problem)
    Writer.Written.Done(bytes) ->
      saved = SaveFile.bytes(output, bytes, 60000)
      if saved.ok?
        return "wrote #{bytes.size} bytes"
      end
      return "cannot write #{output}: #{saved.message}"
  end
end
