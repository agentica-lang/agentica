# `agentica compiler/catalog.agc [PROBE...]` prints the text form of the builtin catalog (catalog_text.agc) and the answer to each probe: near:WORD, ref:NAME/ARITY, std:NAME, type:WORD, sig:NAME or disp:NAME.
import CatalogText from "catalog_text"

def main() -> Void
  puts(CatalogText.catalog_text(System.args()))
end
