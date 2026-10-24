## The workspace of this machine with downloaded native artifacts verified from the cache alone (no network).
## App and entry programs use this; std/internal/compiler keeps io/host.agc's stub so CORE stays pure plus host.

import Workspace from "../modules/workspace"
import NativeArtifact from "../packages/native_artifact"
import Engine from "native_artifact"
import Host from "host"

# The deadline of a cached artifact verification (no network): the receipt and member reads and hashes.
NATIVE_TIMEOUT_MS = 30_000

## The workspace of this machine, with `std_source` as the reader of the std/ sources and `native_artifact`
## verifying the cache.
export def workspace_with(std_source: Fn[String, Result[String]]) -> Workspace.Workspace
  return Host.workspace_with(std_source).with(native_artifact: &native_cached)
end

## The workspace of this machine for a run with `--stdlib DIR`.
export def workspace() -> Workspace.Workspace
  return workspace_with(&no_std_source)
end

def no_std_source(name: String) -> Result[String]
  return error("this workspace carries no std sources")
end

# The verified local path of the downloaded member named by the request, from the cache alone and without any
# network use. The caller matched the manifest row against the lock; this only verifies the cache object.
def native_cached(request: Workspace.NativeRequest) -> Result[String]
  context = NativeArtifact.Context(file: request.file, key: request.key)
  return Engine.cached(request.cache_root, request.sha256, request.member, context, NATIVE_TIMEOUT_MS)
end
