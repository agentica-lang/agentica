## Module doc of the root.

import Lib from "lib"

## An exported enum.
enum E
  ## A variant.
  V
end

## An exported function.
def api() -> Void
end

private

## A struct.
struct S
  ## A field.
  a: Int
end

## Main.
def main() -> Void
  Lib.go()
end
