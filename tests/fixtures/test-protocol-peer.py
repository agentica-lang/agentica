import json
import subprocess
import sys

MARKER = "\x1eagentica-bdd "
TOKEN = "peer-token-7"


def start(vm, bytecode, mode):
    return subprocess.Popen(
        [vm, "--json", "--", bytecode, "--agentica-test", mode],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def record(line):
    if not line.startswith(MARKER):
        return None
    try:
        found = json.loads(line[len(MARKER):])
    except ValueError:
        return None
    if not isinstance(found, dict) or found.get("token") != TOKEN:
        return None
    return found


def listed(vm, bytecode):
    child = start(vm, bytecode, "list")
    out, _ = child.communicate(TOKEN + "\n", timeout=30)
    records = [found for found in map(record, out.split("\n")) if found]
    if not records or records[-1].get("event") != "ready":
        raise SystemExit("the list child did not answer ready: " + out)
    return [found["name"] for found in records if found.get("event") == "test"], child.returncode


def run(vm, bytecode, count):
    child = start(vm, bytecode, "run")
    child.stdin.write(TOKEN + "\n")
    results = []
    for index in range(count):
        child.stdin.write("%d\n" % index)
        child.stdin.flush()
        output = []
        while True:
            line = child.stdout.readline()
            if line == "":
                raise SystemExit("the run child ended during test %d" % index)
            line = line.rstrip("\n")
            found = record(line)
            if found is None:
                output.append(line)
                continue
            results.append([found["event"], found.get("code"), output])
            break
    child.stdin.close()
    child.stdout.read()
    return results, child.wait(timeout=30)


def main():
    vm, bytecode = sys.argv[1], sys.argv[2]
    names, list_exit = listed(vm, bytecode)
    results, run_exit = run(vm, bytecode, len(names))
    print(json.dumps({"names": names, "list_exit": list_exit, "results": results, "run_exit": run_exit}))


if __name__ == "__main__":
    main()
