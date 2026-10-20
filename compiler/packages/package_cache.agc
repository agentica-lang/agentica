## Where the files of a package are kept (docs/future/45-packages.md, 45.8): a folder for each commit of each package,
## under the cache root. The build only reads it; filling it is the job of install (a later phase).

import GitSource from "git_source"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"

## The folder that holds the packages: `$XDG_CACHE_HOME/agentica/pkg`, which is `~/.cache/agentica/pkg` when
## XDG_CACHE_HOME is not set or not absolute. On Windows it is `%LOCALAPPDATA%/agentica/cache/pkg` (the user data
## folder of Windows, as for pkg/ libraries; XDG_CACHE_HOME and HOME are not read there). It is "" when the variables
## leave no place for it: an unset HOME, or a relative or unset LOCALAPPDATA.
export def root(env: Env.Env) -> String
  if env.windows
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

## The folder of one commit of the package at this git URL: `<root>/<host>/<owner>/<repo>/<commit>`. The commit in the
## path means two versions never share a folder, and the URL (not the local name) decides the place, so two projects
## that name one repository differently share its folder.
export def folder(root: String, git: String, commit: String) -> String
  return Paths.join(Paths.join(root, GitSource.cache_path(git)), commit)
end
