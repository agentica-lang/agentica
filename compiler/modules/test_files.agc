## Which root files are tests, by their names: a `*_test.agc` file is a unit test file and `steps.agc` the step program
## that `agentica test` finds by itself. `agentica test` compiles them as tests; `check`, the queries and std/analysis
## decide by these names, so a test file that imports the test group of the manifest (`group = "test"`) checks there
## too. A step program given with `agentica test --steps FILE` under another name is a test only under `agentica test`.

import Env from "link_env"

## The name of the step program that `agentica test` finds by itself in the folders of the features.
STEPS_FILE = "steps.agc"

## True for the name of a unit test file, `*_test.agc`.
def test_file?(path: String) -> Bool = path.end_with?("_test.agc")

## True for the name of that step program, `steps.agc`, as a path of any system.
def steps_file?(path: String) -> Bool
  path == STEPS_FILE or path.end_with?("/#{STEPS_FILE}") or path.end_with?("\\#{STEPS_FILE}")
end

## `settings` for the root file `path`, as its name says: a test file is one (Settings.test_file), and a step program
## a test build (Settings.test_build). Both may import the test group.
def for_root(settings: Env.Settings, path: String) -> Env.Settings
  settings.with(test_file: test_file?(path), test_build: steps_file?(path))
end
