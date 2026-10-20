## Where the files of a package are kept (docs/future/45-packages.md, 45.8): a folder for each commit of each package,
## under the cache root. The build only reads it; filling it is the job of install (a later phase).

import Env from "link_env"
import Paths from "import_path"

## The folder that holds the packages: `$XDG_CACHE_HOME/agentica/pkg`, which is `~/.cache/agentica/pkg` when
## XDG_CACHE_HOME is not set or not absolute. On Windows it is `%LOCALAPPDATA%/agentica/cache/pkg` (the user data
## folder of Windows, as for pkg/ libraries; XDG_CACHE_HOME and HOME are not read there). It is "" when the variables
## leave no place for it: an unset HOME, or a relative or unset LOCALAPPDATA.
export def root(env: Env.Env, on_windows: Bool) -> String
  if on_windows
    if Paths.absolute?(env.local_app_data, true)
      return Paths.join(env.local_app_data, "agentica/cache/pkg")
    end
    return ""
  elsif env.xdg_cache_home.starts_with?("/")
    return Paths.join(env.xdg_cache_home, "agentica/pkg")
  elsif env.home != ""
    return Paths.join(env.home, ".cache/agentica/pkg")
  end
  return ""
end

## The folder of one commit of the package with this key: `<root>/<host>/<owner>/<repo>/<commit>`. GitHub is the host
## `github.com`, and its keys do not write it. The commit in the path means two versions never share a folder.
export def folder(root: String, key: String, commit: String) -> String
  host_and_path = key
  if !Paths.first_part(key).contains?(".")
    host_and_path = "github.com/#{key}"
  end
  return Paths.join(Paths.join(root, host_and_path), commit)
end
