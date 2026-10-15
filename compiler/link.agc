import "link_env" as Env
import "link_text" as LinkText

# `agentica compiler/link.agc [flags] ROOT...` prints the text form of linking each root file (link_text.agc). The flags apply to the roots after them. `--stdlib=DIR` is the stdlib/ folder (the default is stdlib). `--agentica-path=V`, `--xdg-data-home=V` and `--home=V` replace the environment variable of the pkg/ search (the process environment otherwise). `--ids` prints the id ranges of the files instead (ids_text).
def main() -> Void
  stdlib = "stdlib"
  env = Env.process_env()
  ids = false
  for argument in System.args()
    if argument.starts_with?("--stdlib=")
      stdlib = argument.slice(9, argument.length - 9)
    elsif argument.starts_with?("--agentica-path=")
      env = env.with(agentica_path: argument.slice(16, argument.length - 16))
    elsif argument.starts_with?("--xdg-data-home=")
      env = env.with(xdg_data_home: argument.slice(16, argument.length - 16))
    elsif argument.starts_with?("--home=")
      env = env.with(home: argument.slice(7, argument.length - 7))
    elsif argument == "--ids"
      ids = true
    else
      puts("== " + argument)
      settings = Env.settings(stdlib, env)
      if ids
        puts(LinkText.ids_text(argument, settings))
      else
        puts(LinkText.link_text(argument, settings))
      end
    end
  end
end
