## The help of an unknown import name: the "did you mean" of the linker.

import Builtins from "../catalog/builtins"
import Diag from "../diagnostics/diagnostic"
import Suggest from "../syntax/suggest"
import Declarations from "declarations"

# The std/http server forms that `serve` replaced: the two whose handler `HTTP.app` takes as it is, and the others
# (streams, uploads, upgrades), whose handler types went with them.
WHOLE_FORMS = ["listen", "listen_tls"]
OTHER_FORMS = [
  "listen_stream",
  "listen_stream_tls",
  "listen_upload",
  "listen_upload_tls",
  "listen_websocket",
  "listen_websocket_tls",
  "upgrade_only",
  "StreamHandler",
  "UploadHandler",
  "UpgradeHandler",
]

## The help of CHECK-IMPORT-NAME for member, which the module key does not export: the fixed texts for the removed
## std/http functions and std/logger error, the new name of a builtin type that moved into a std/ module (LogEvent),
## or the did-you-mean over the exports (a private name is never suggested).
export def unknown_import_help(key: String, exports: Map[String, Declarations.Kind], member: String) -> Diag.Help
  removed = ["respond", "begin", "write", "write_bytes"].any? do |name| name == member end
  whole = WHOLE_FORMS.any? do |name| name == member end
  other = OTHER_FORMS.any? do |name| name == member end
  if key == "std/http.agc" and removed
    return Diag.Help.Hint(
      "a handler returns its whole response: return ok(HttpResponse(status: 200, headers: [], body: text.bytes))",
    )
  elsif key == "std/http.agc" and whole
    return Diag.Help.Hint("HTTP.serve replaces it: HTTP.serve(host, port, HTTP.app(&handle), options)")
  elsif key == "std/http.agc" and other
    return Diag.Help.Hint(
      "HTTP.serve serves every kind of route with an HTTP.App; the table \"Moving from the listen forms\" of the " +
      "network page gives the new form",
    )
  elsif key == "std/logger.agc" and member == "error"
    return Diag.Help.Hint("the function for the error level is Logger.err; error is a reserved name")
  elsif key.starts_with?("std/") and Builtins.moved_type(member) != ""
    return Diag.Help.Hint(Builtins.moved_type(member))
  end

  case Suggest.closest_among(member, exports.keys, [])
    some(name) -> Diag.Help.Hint("did you mean \"#{name}\"?")
    none -> Diag.Help.NoHelp
  end
end
