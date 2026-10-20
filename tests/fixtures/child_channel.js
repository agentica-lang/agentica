// Starts a VM as the child of a Node peer with a child channel (docs/vm/10-io-processes.md, 10.4): the common part of
// child-channel-peer.js, test-protocol-peer.js and channel-run.js (the Node twin of child_channel.py).
//
// The channel is one socket pair at descriptor 3 where the system has one (marker "3"), and one pipe per direction at
// descriptors 3 (to the child) and 4 (from the child) on Windows (marker "3,4"), the form node itself gives when it
// asks for two extra pipes: libuv hands the CRT of a Windows child its descriptor table in lpReserved2.
//
// The order of stdout and channel. Two Node streams over two pipes say nothing about which byte was written first: both
// are read by libuv from one completion port, but libuv asks for the next read of a pipe only after it has handled the
// last one, so a stdout write that comes just before a channel record can be delivered after the record's 'data' event
// (seen in about one run in ten of the test protocol). The peer therefore does not read stdout from a pipe. With
// `stdout: "file"` the child's stdout is a file, and `takeStdout()` reads what the file holds at that moment, in the
// middle of a handler and without waiting. The order is then given by the protocol, not by any delay:
//   1. The child flushes its stdout before it sends a channel record (10.4, `agc_drain`), so everything the child
//      printed for a request is in the file before the record is in the channel.
//   2. The peer sends the next request only after it has read the record of the one before (lock step), so the output
//      of request N+1 cannot start before the peer has the record of request N.
// So at the 'data' event of a record, `takeStdout()` is exactly the stdout that belongs before that record.
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const MARKER = "AGENTICA_CHANNEL";
const WINDOWS = process.platform === "win32";

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

// The children that are alive, for the watchdog.
const alive = new Set();

// Ends the peer with status 124 and kills its children when it is still running after `ms` milliseconds: a hung VM
// never keeps a test waiting. The timer does not keep a finished peer alive.
function watchdog(ms) {
  setTimeout(() => {
    for (const child of alive) child.kill();
    process.stderr.write("the peer ran longer than " + ms + " ms\n");
    process.exit(124);
  }, ms).unref();
}

// A file for the stdout of a child: [the descriptor the child gets, the one the peer reads]. The file is removed at once where the system lets an open file go (Windows and POSIX both do, and then it cannot outlive a
// peer that is killed), and when the removal fails, the peer removes it when it ends.
function stdoutFile() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "agentica-peer-"));
  const file = path.join(directory, "stdout");
  const write = fs.openSync(file, "w");
  const read = fs.openSync(file, "r");
  try {
    fs.unlinkSync(file);
    fs.rmdirSync(directory);
  } catch (error) {
    process.on("exit", () => fs.rmSync(directory, { recursive: true, force: true }));
  }
  return [write, read];
}

// Starts `argv` with a channel (or only the marker, or none) and returns the ways to use it.
// The marker defaults to the one of this system; null leaves it out. `stdin` and `stderr` are "pipe", "ignore" or
// "inherit" (stdin defaults to "ignore", stderr to "pipe"); `stdout` is "pipe", or "file" for a stdout that keeps its
// order with the channel (see above), which `takeStdout()` and `stdout()` then read.
function launch(
  argv,
  { channel = true, marker = WINDOWS ? "3,4" : "3", stdin = "ignore", stderr = "pipe", stdout = "pipe" } = {}
) {
  const env = Object.assign({}, process.env);
  delete env[MARKER];
  if (marker !== null) env[MARKER] = marker;
  const [written, read] = stdout === "file" ? stdoutFile() : [null, null];
  const stdio = [stdin, stdout === "file" ? written : "pipe", stderr];
  if (channel) stdio.push("pipe");
  if (channel && WINDOWS) stdio.push("pipe");
  let child;
  try {
    child = spawn(argv[0], argv.slice(1), { stdio, env });
  } finally {
    if (written !== null) fs.closeSync(written);
  }
  alive.add(child);
  const output = [];
  let taken = 0;
  if (child.stdout) child.stdout.on("data", (chunk) => output.push(chunk));
  // What the file holds beyond what was read before, read at this moment.
  let position = 0;
  const pull = () => {
    const chunks = [];
    for (;;) {
      const chunk = Buffer.alloc(65536);
      const n = fs.readSync(read, chunk, 0, chunk.length, position);
      if (n === 0) break;
      position += n;
      chunks.push(chunk.subarray(0, n));
    }
    output.push(...chunks);
    return Buffer.concat(chunks);
  };
  const errors = [];
  if (child.stderr) child.stderr.on("data", (chunk) => errors.push(chunk));
  if (child.stdin) child.stdin.on("error", () => {});
  // The exit status, or null for a child that a signal ended.
  const exited = new Promise((resolve) =>
    child.on("close", (code) => {
      alive.delete(child);
      resolve(code);
    })
  );
  const toChild = channel ? child.stdio[3] : null;
  const fromChild = channel ? child.stdio[WINDOWS ? 4 : 3] : null;
  if (toChild) toChild.on("error", () => {});
  return {
    child,
    exited,
    toChild,
    fromChild,
    send: (data) => new Promise((resolve) => toChild.write(data, () => resolve())),
    // The end of input: a half close of the socket, or on Windows the close of the pipe the child reads. The data
    // sent before it has been written, since send waits for its write.
    endInput: () => new Promise((resolve) => (WINDOWS ? resolve(toChild.destroy()) : toChild.end(resolve))),
    line: fromChild ? reader(fromChild) : null,
    close: () => {
      if (toChild) toChild.destroy();
      if (fromChild) fromChild.destroy();
      if (read !== null) fs.closeSync(read);
    },
    // All of the stdout.
    stdout: () => {
      if (read !== null) pull();
      return Buffer.concat(output).toString("utf8");
    },
    // The stdout the child has written since the last call (a Buffer). The stdout of a "file" is read at the moment of
    // the call; the stdout of a "pipe" is what the 'data' events have delivered so far.
    takeStdout: () => {
      if (read !== null) return pull();
      const all = Buffer.concat(output);
      const fresh = all.subarray(taken);
      taken = all.length;
      return fresh;
    },
    stderr: () => Buffer.concat(errors).toString("utf8"),
  };
}

module.exports = { MARKER, WINDOWS, launch, reader, watchdog };
