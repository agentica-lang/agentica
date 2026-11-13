## The names of the compiler prelude (stdlib/prelude/, docs/vm/03-ir-and-bytecode.md §4.7). The checker reads the
## prelude files, the linker must not take them for a user file and lowering flags them, so the names live in the first
## stage that needs them.

## The start of the name of a source file of the compiler prelude. The prelude has no text in the program: the file is
## a name, with no text, and every span of its functions is its first character.
PRELUDE_PREFIX = "<prelude>/"

## The name, in the lowered program, of the prelude function with this key: "list::find" is the function find of
## stdlib/prelude/list.agc. The prefix cannot start the name of a function of a program.
def prelude_name(key: String) -> String = "@prelude::" + key
