# to_a on an endless source never ends: --max-steps stops it, since every item pulled costs a step.
def main() -> Void
  puts((0..9000000000000000000).lazy.drop(1).to_a)
end
