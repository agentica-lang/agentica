import Host from "../../../compiler/io/host"
import Lock from "../../../compiler/packages/lock"

# Reads the lock in the first argument and prints Lock.encode of what it read, for the round trip case of
# tests/test_spec_package_namespace.py. A refused lock prints its diagnostic code.

def main() -> Void
  case Lock.read(Host.workspace(), System.args()[0])
    ok(lock) -> print(Lock.encode(lock.packages, lock.artifacts))
    error(packed) -> puts("ERR #{packed.message}")
  end
end
