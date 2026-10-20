// The Node twin of test-protocol-peer.py, for Windows (where Python cannot give a child two pipes at descriptors 3 and
// 4): drives a test program of fixtures/test-protocol-peer.agc over the child channel of `--agentica-test` and prints
// what it saw as JSON.
//
//   node test-protocol-peer.js VM BYTECODE
//
// The output of a test is what the child wrote to stdout between the previous record and this one. That is the true
// attribution because the child flushes stdout before each record and the peer asks for the next test only after it has
// the record of the one before; the child's stdout is a file that the peer reads when the record arrives, since two
// pipes would not keep the order (child_channel.js).
"use strict";
const { launch, watchdog } = require("./child_channel.js");

const start = (vm, bytecode, mode, options = {}) =>
  launch([vm, "run", "--json", "--", bytecode, "--agentica-test", mode], { stdin: "pipe", stdout: "file", ...options });

// The end of a run: the input of the channel and of stdin ends, and the peer waits for the child to exit.
async function finish(peer) {
  if (peer.toChild) await peer.endInput();
  peer.child.stdin.end();
  const code = await peer.exited;
  // The stdout that no record has taken.
  const stdout = peer.takeStdout().toString("utf8");
  peer.close();
  return { code, stdout, stderr: peer.stderr() };
}

async function listed(vm, bytecode) {
  const peer = start(vm, bytecode, "list");
  const records = [];
  for (let line = await peer.line(); line !== ""; line = await peer.line()) records.push(JSON.parse(line));
  const { code, stdout } = await finish(peer);
  if (records.length === 0 || records[records.length - 1].event !== "ready") {
    throw new Error("the list child did not answer ready: " + JSON.stringify(records));
  }
  return { names: records.filter((found) => found.event === "test").map((found) => found.name), code, stdout };
}

async function run(vm, bytecode, count) {
  const peer = start(vm, bytecode, "run");
  try {
    const results = [];
    peer.child.stdin.write("from the peer\n");
    for (let index = 0; index < count; index++) {
      await peer.send(index + "\n");
      const line = await peer.line();
      if (line === "") throw new Error("the run child ended during test " + index);
      const found = JSON.parse(line);
      const code = found.code === undefined ? null : found.code;
      results.push([found.event, code, peer.takeStdout().toString("utf8")]);
    }
    const { code, stdout } = await finish(peer);
    return { results, code, stdout };
  } finally {
    peer.child.kill();
  }
}

async function withoutChannel(vm, bytecode) {
  const peer = start(vm, bytecode, "list", { channel: false, marker: null });
  const { code, stdout, stderr } = await finish(peer);
  const last = stderr.split("\n").filter((line) => line !== "").pop();
  return { code, diagnostic: JSON.parse(last).code, stdout };
}

async function main() {
  const [vm, bytecode] = process.argv.slice(2);
  watchdog(100000);
  const names = await listed(vm, bytecode);
  const ran = await run(vm, bytecode, names.names.length);
  const bare = await withoutChannel(vm, bytecode);
  process.stdout.write(
    JSON.stringify({
      names: names.names,
      list_exit: names.code,
      list_stdout: names.stdout,
      results: ran.results,
      run_exit: ran.code,
      run_stdout: ran.stdout,
      bare_exit: bare.code,
      bare_code: bare.diagnostic,
      bare_stdout: bare.stdout,
    }) + "\n"
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
