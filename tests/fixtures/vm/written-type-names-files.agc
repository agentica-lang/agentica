# A std/ record prints with the alias of the first file that imports its module with one: an alias written only in
# another file (W.Download), and the root's first written alias before a later one and before another file's (Z.Value).
import Z from "std/toml"
import A from "std/toml"
import {download, number} from "lib/written_aliases"

def main() -> Void
  puts(download())
  puts(number())
  puts(A.Value.Bool(true))
  puts(Z.Value.Int(3))
end
