import json
import socket
import subprocess
import sys

from child_channel import launch, lines, read_ready


def start(vm, bytecode, mode, channel=True):
    argv = [vm, "--json", "--", bytecode, "--agentica-test", mode]
    if channel:
        return launch(argv)
    return subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE), None


def finish(child, channel):
    if channel is not None:
        channel.shutdown(socket.SHUT_WR)
    child.stdin.close()
    out = child.stdout.read()
    err = child.stderr.read()
    return child.wait(timeout=30), out.decode(), err.decode()


def listed(vm, bytecode):
    child, channel = start(vm, bytecode, "list")
    reader = lines(channel)
    records = [json.loads(line) for line in reader]
    code, out, _ = finish(child, channel)
    if not records or records[-1].get("event") != "ready":
        raise SystemExit("the list child did not answer ready: %r" % records)
    return [found["name"] for found in records if found.get("event") == "test"], code, out


def run(vm, bytecode, count):
    child, channel = start(vm, bytecode, "run")
    reader = lines(channel)
    results = []
    try:
        child.stdin.write(b"from the peer\n")
        child.stdin.flush()
        for index in range(count):
            channel.sendall(b"%d\n" % index)
            line = reader.readline()
            if line == "":
                raise SystemExit("the run child ended during test %d" % index)
            found = json.loads(line)
            results.append([found["event"], found.get("code"), read_ready(child.stdout)])
        code, out, _ = finish(child, channel)
        return results, code, out
    finally:
        child.kill()
        child.wait()


def without_channel(vm, bytecode):
    child, _ = start(vm, bytecode, "list", channel=False)
    code, out, err = finish(child, None)
    last = [line for line in err.split("\n") if line][-1]
    return code, json.loads(last)["code"], out


def main():
    vm, bytecode = sys.argv[1], sys.argv[2]
    names, list_exit, list_out = listed(vm, bytecode)
    results, run_exit, run_out = run(vm, bytecode, len(names))
    code, diagnostic, silent = without_channel(vm, bytecode)
    print(json.dumps({
        "names": names,
        "list_exit": list_exit,
        "list_stdout": list_out,
        "results": results,
        "run_exit": run_exit,
        "run_stdout": run_out,
        "bare_exit": code,
        "bare_code": diagnostic,
        "bare_stdout": silent,
    }))


if __name__ == "__main__":
    main()
