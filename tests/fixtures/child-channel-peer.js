// The independent peer of the child channel (docs/vm/10-io-processes.md, 10.4), for every system.
//
//   node child-channel-peer.js VM BYTECODE        drives the child side: spawns the VM as the child, prints JSON
//   node child-channel-peer.js child MODE         is the child the parent side spawns
//
// The channel is one socket pair at descriptor 3 where the system has one (marker "3"), and one pipe per direction
// at descriptors 3 (to the child) and 4 (from the child) on Windows (marker "3,4"), the form node itself gives
// when it asks for two extra pipes.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { MARKER, WINDOWS, launch, writeAll } = require("./child_channel.js");

// ---- the parent side: this program drives a VM that is the child ----

async function finish(peer, started, extra = {}) {
  const timer = setTimeout(() => peer.child.kill("SIGKILL"), 30000);
  const exit = await peer.exited;
  clearTimeout(timer);
  peer.close();
  return Object.assign({ exit, stdout: peer.stdout(), stderr: peer.stderr(), waited: Date.now() - started >= 250 }, extra);
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function serve(vm, bytecode) {
  const peer = launch([vm, "run", "--", bytecode, "serve"]);
  const started = Date.now();
  const replies = [];
  await peer.send("one\n");
  replies.push(await peer.line());
  await peer.send("tw");
  await pause(200);
  await peer.send("o\n\n");
  replies.push(await peer.line());
  replies.push(await peer.line());
  await peer.send("y".repeat(300000) + "\n");
  replies.push((await peer.line()).length);
  await peer.send("café\n");
  replies.push(await peer.line());
  await peer.endInput();
  replies.push(await peer.line());
  replies.push(await peer.line());
  return finish(peer, started, { replies });
}

function held(vm, bytecode, mode, options) {
  const peer = launch([vm, "run", "--", bytecode, mode], options);
  return finish(peer, Date.now());
}

// Windows: descriptors 3 and 4 that are a file, or NUL, behind the marker "3,4" (the POSIX form, with the descriptor 3
// of a file, a device or a FIFO, is in child-channel-peer.py): the child must refuse them as a channel.
async function pinned(vm, bytecode) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "agentica-pinned-"));
  try {
    const answers = {};
    for (const kind of ["file", "device"]) {
      const target = kind === "file" ? path.join(directory, "plain.txt") : "NUL";
      const fd = fs.openSync(target, "w+");
      try {
        answers[kind] = await held(vm, bytecode, "pinned", { channel: false, pins: [fd, fd] });
      } finally {
        fs.closeSync(fd);
      }
    }
    answers.file.content = fs.readFileSync(path.join(directory, "plain.txt"), "utf8");
    return answers;
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

async function drive(vm, bytecode) {
  const answer = {};
  if (WINDOWS) answer.pinned = await pinned(vm, bytecode);
  answer.serve = await serve(vm, bytecode);
  answer.idle = await held(vm, bytecode, "idle");
  answer.bare = await held(vm, bytecode, "bare", { marker: null });
  // The marker of the other system and no descriptor behind it.
  answer.bare_marker_only = await held(vm, bytecode, "bare", { channel: false, marker: "3" });
  answer.bare_marker_pair_only = await held(vm, bytecode, "bare", { channel: false, marker: "3,4" });
  return answer;
}

// ---- the child side: the VM is the parent that spawned this program ----

// The descriptors the marker names, or null when this program was not given a channel.
function ends() {
  const marker = process.env[MARKER];
  if (marker === "3") return { read: 3, write: 3 };
  if (marker === "3,4") return { read: 3, write: 4 };
  return null;
}

// The errors that mean the other end is gone: a socket reset, or a broken or closed pipe on Windows.
const ENDED = new Set(["EOF", "EPIPE", "ECONNRESET", "ERROR_BROKEN_PIPE"]);

// Reads one line (with its "\n") from the descriptor; null is the end of input. Any other error is thrown.
function readLine(fd) {
  const one = Buffer.alloc(1);
  const bytes = [];
  const deadline = Date.now() + 30000;
  for (;;) {
    let n = 0;
    try {
      n = fs.readSync(fd, one, 0, 1, null);
    } catch (error) {
      // A descriptor that was given non-blocking has nothing yet: wait a little and read again.
      if (error.code === "EAGAIN" && Date.now() < deadline) {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
        continue;
      }
      if (ENDED.has(error.code)) return null;
      throw error;
    }
    if (n === 0) return null;
    bytes.push(one[0]);
    if (one[0] === 10) return Buffer.from(bytes);
  }
}

function asChild(mode) {
  if (mode === "plain") {
    const marker = process.env[MARKER] === undefined ? "None" : process.env[MARKER];
    // Node keeps descriptors of its own at 3 (an epoll, a wake-up pipe), so only the marker says what the parent gave.
    writeAll(1, "marker=" + marker + "\n");
    return;
  }
  const channel = ends();
  if (channel === null) throw new Error("child mode " + mode + " needs the channel, and AGENTICA_CHANNEL is not 3 or 3,4");
  if (mode === "echo") {
    const data = readLine(channel.read);
    if (data === null) return;
    writeAll(1, "out:" + data.toString().trim() + "\n");
    writeAll(channel.write, data.toString().toUpperCase());
    while (readLine(channel.read) !== null);
  } else if (mode === "long") {
    writeAll(channel.write, "x".repeat(1048700));
    return pause(30000);
  } else if (mode === "loud") {
    writeAll(1, "noise\n");
    writeAll(channel.write, "done\n");
    return pause(30000);
  } else if (mode === "split") {
    writeAll(1, Buffer.from([0x61, 0xc3]));
    writeAll(channel.write, "one\n");
    readLine(channel.read);
    writeAll(1, Buffer.from([0xa9, 0x62, 0x0a]));
    writeAll(channel.write, "two\n");
    return pause(30000);
  } else if (mode === "gone") {
    return;
  } else if (mode === "watch") {
    // Reports its pid, then reads until the parent's end goes away and leaves a mark file (argument 4) saying so.
    writeAll(1, process.pid + "\n");
    let mark = "end\n";
    try {
      while (readLine(channel.read) !== null);
    } catch (error) {
      mark = "error:" + error.code + "\n";
    }
    fs.writeFileSync(process.argv[4], mark);
  } else {
    return pause(30000);
  }
}

async function main() {
  if (process.argv[2] === "child") {
    await asChild(process.argv[3]);
    return;
  }
  console.log(JSON.stringify(await drive(process.argv[2], process.argv[3])));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
