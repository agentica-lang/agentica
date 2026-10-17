import Paths from "../../../compiler/import_path"
import Imports from "../../../compiler/resolve_import"

def main() -> Void
  for path in System.args()
    puts("#{Paths.rooted?(path)} #{Imports.embedded?(path)}")
  end
end
