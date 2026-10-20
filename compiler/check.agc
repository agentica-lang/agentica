import Env from "link_env"
import CheckText from "check_text"

# `agentica compiler/check.agc [flags] ROOT...` prints the text form of checking each root file (check_text.agc). The
# flags are those of link.agc: `--stdlib=DIR` (the default is stdlib), `--agentica-path=V`, `--xdg-data-home=V`,
# `--xdg-cache-home=V`, `--home=V` and `--local-app-data=V`.
def main() -> Void
  stdlib = "stdlib"
  env = Env.process_env()
  for argument in System.args()
    if argument.starts_with?("--stdlib=")
      stdlib = argument.slice(9, argument.length - 9)
    elsif argument.starts_with?("--agentica-path=")
      env = env.with(agentica_path: argument.slice(16, argument.length - 16))
    elsif argument.starts_with?("--xdg-data-home=")
      env = env.with(xdg_data_home: argument.slice(16, argument.length - 16))
    elsif argument.starts_with?("--xdg-cache-home=")
      env = env.with(xdg_cache_home: argument.slice(17, argument.length - 17))
    elsif argument.starts_with?("--home=")
      env = env.with(home: argument.slice(7, argument.length - 7))
    elsif argument.starts_with?("--local-app-data=")
      env = env.with(local_app_data: argument.slice(17, argument.length - 17))
    else
      puts("== #{argument}")
      puts(CheckText.check_text(argument, Env.settings(stdlib, env)))
    end
  end
end
