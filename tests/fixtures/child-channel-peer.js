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
const { spawn } = require("child_process");

const MARKER = "AGENTICA_CHANNEL";
const WINDOWS = process.platform === "win32";

// ---- the parent side: this program drives a VM that is the child ----

// A line reader over a stream; the line keeps its "\n", and "" is the end of the stream.
function reader(stream) {
  let buffer = Buffer.alloc(0);
  let ended = false;
  let wake = null;
  const notify = () => {
    if (wake) wake();
  };
  stream.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    notify();
  });
  const finish = () => {
    ended = true;
    notify();
  };
  stream.on("end", finish);
  stream.on("close", finish);
  stream.on("error", finish);
  return async function line() {
    for (;;) {
      const at = buffer.indexOf(10);
      if (at >= 0) {
        const text = buffer.subarray(0, at + 1).toString("utf8");
        buffer = buffer.subarray(at + 1);
        return text;
      }
      if (ended) {
        const rest = buffer.toString("utf8");
        buffer = Buffer.alloc(0);
        return rest;
      }
      await new Promise((resolve) => {
        wake = resolve;
      });
      wake = null;
    }
  };
}

// Starts `argv` with a channel (or only the marker, or none) and returns the ways to use it.
// The marker defaults to the one of this system; null leaves it out.
function launch(argv, { channel = true, marker = WINDOWS ? "3,4" : "3" } = {}) {
  const env = Object.assign({}, process.env);
  delete env[MARKER];
  if (marker !== null) env[MARKER] = marker;
  const stdio = ["ignore", "pipe", "pipe"];
  if (channel) stdio.push("pipe");
  if (channel && WINDOWS) stdio.push("pipe");
  const child = spawn(argv[0], argv.slice(1), { stdio, env });
  const output = [];
  child.stdout.on("data", (chunk) => output.push(chunk));
  child.stderr.resume();
  const exited = new Promise((resolve) => child.on("close", (code) => resolve(code)));
  const toChild = channel ? child.stdio[3] : null;
  const fromChild = channel ? child.stdio[WINDOWS ? 4 : 3] : null;
  if (toChild) toChild.on("error", () => {});
  return {
    child,
    exited,
    send: (data) => new Promise((resolve) => toChild.write(data, () => resolve())),
    // The end of input: a half close of the socket, or on Windows the close of the pipe the child reads.
    endInput: () => new Promise((resolve) => (WINDOWS ? resolve(toChild.destroy()) : toChild.end(resolve))),
    line: fromChild ? reader(fromChild) : null,
    close: () => {
      if (toChild) toChild.destroy();
      if (fromChild) fromChild.destroy();
    },
    stdout: () => Buffer.concat(output).toString("utf8"),
  };
}

async function finish(peer, started, extra = {}) {
  const timer = setTimeout(() => peer.child.kill("SIGKILL"), 30000);
  const exit = await peer.exited;
  clearTimeout(timer);
  peer.close();
  return Object.assign({ exit, stdout: peer.stdout(), waited: Date.now() - started >= 250 }, extra);
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function serve(vm, bytecode) {
  const peer = launch([vm, "run", "--allow-run", "--", bytecode, "serve"]);
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
  const peer = launch([vm, "run", "--allow-run", "--", bytecode, mode], options);
  return finish(peer, Date.now());
}

async function drive(vm, bytecode) {
  const answer = {};
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

function readLine(fd) {
  const one = Buffer.alloc(1);
  const bytes = [];
  for (;;) {
    let n = 0;
    try {
      n = fs.readSync(fd, one, 0, 1, null);
    } catch (error) {
      // A descriptor that was given non-blocking has nothing yet: wait a little and read again.
      if (error.code === "EAGAIN") {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
        continue;
      }
      n = 0; // a closed pipe may report itself as an error instead of an end
    }
    if (n === 0) return null;
    bytes.push(one[0]);
    if (one[0] === 10) return Buffer.from(bytes);
  }
}

function writeAll(fd, data) {
  let buffer = Buffer.from(data);
  while (buffer.length > 0) {
    const n = fs.writeSync(fd, buffer);
    buffer = buffer.subarray(n);
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
    while (readLine(channel.read) !== null);
    fs.writeFileSync(process.argv[4], "end\n");
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
