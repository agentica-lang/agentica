/*
 * What the two ways of starting a VM in the agentica binary (agentica.c) share:
 * the front end's run and `agentica run`. The options of a run, the start of a
 * runtime from a loaded program, and the one way a run ends. Driver header.
 * Design: docs/vm/08-loader-and-cli.md.
 */
#ifndef AGC_LAUNCH_H
#define AGC_LAUNCH_H

#include "port.h"

/* The options that the VM takes before the program. max_steps and flush_timeout are the values after the defaults
 * and the flags; the seen_ flags say what was typed (the environment may still set the flush timeout). embedded is the
 * word after --embedded, which only `agentica run` takes: the program is one the binary carries, not a file. */
typedef struct {
  int64_t max_steps, flush_timeout, driver;
  uint32_t seed;
  agc_style style;
  const char *source_root;
  const char *embedded;
  size_t source_root_chars;
  bool seen_flush, seen_seed, seen_driver, allow_run;
} agc_launch_options;

typedef enum { AGC_LAUNCH_OK, AGC_LAUNCH_VERSION, AGC_LAUNCH_BAD } agc_launch_status;

/* What the process keeps for all of its runtimes: the trace settings, the pipes it was started with, and whether
 * this process set UV_USE_IO_URING (libuv's setup runs once per process, and a child must not inherit it). */
typedef struct {
  agc_trace trace;
  agc_file_ids inherited;
  bool io_started, own_uring_env;
} agc_launch;

/* Makes a write to a closed pipe fail with EPIPE instead of ending the process with SIGPIPE. agc_launch_init does it;
 * a caller that answers something before agc_launch_init (agentica --version) calls this first. */
void agc_launch_ignore_sigpipe(void);

/* Starts the process: fills closed standard descriptors, ignores SIGPIPE, starts the allocator and notes the pipes
 * that came with the process. Call it first. */
void agc_launch_init(agc_launch *launch);
bool agc_launch_utf8_args(int *argc, char ***argv);

/* Reads the options at argv[*at] and on, up to a "--" (skipped), the first word that is not an option, or argc.
 * *at is left on the first word that was not read. On AGC_LAUNCH_BAD the message is already on stderr, started
 * with NAME ("agentica run: ..."). AGC_LAUNCH_VERSION stops the read at --version, which only `agentica run` answers. */
agc_launch_status agc_launch_parse(const char *name, int argc, char **argv, int *at, agc_launch_options *options);

/* The options of a run that has no flags. */
void agc_launch_defaults(agc_launch_options *options);

/* Applies AGENTICA_FLUSH_TIMEOUT_MS unless --flush-timeout was given. False, with a message on stderr, when the
 * variable is not valid. */
bool agc_launch_flush_env(const char *name, agc_launch_options *options);

/* --driver-pid: false when the parent process is not the driver that named itself. */
bool agc_launch_bind(int64_t driver);

const char *agc_launch_self_path(int argc, char **argv, const char *fallback, char *buffer, size_t size);

/* Reads AGENTICA_VM_TRACE and AGENTICA_VM_TRACE_FILE into launch->trace. */
void agc_launch_trace(agc_launch *launch);

/* The arguments of a program as a List[String]: argv[first] and on. */
agc_value agc_launch_args(int argc, char **argv, int first);

/* Reads a whole regular file of at most AGC_MAX_FILE_BYTES from an open descriptor of known size. NULL when it
 * cannot be read in full; the descriptor is closed either way. */
uint8_t *agc_launch_read(int fd, size_t size);
uint8_t *agc_launch_file(const char *path, bool driven, size_t *size);

/* A runtime for PROGRAM, ready to run: output on descriptors 1 and 2, the stop signals watched, the seed and the
 * options applied. A front end (FRONT_END not NULL, the compiler of the single binary) gets that structure in its
 * runtime and neither standard input nor the channel to a parent process; they stay with the user's program, which
 * is the run that has FRONT_END NULL. */
agc_vm *agc_launch_vm(agc_launch *launch, const agc_program *program, const agc_launch_options *options,
                      agc_value args, agc_front_end *front_end);

/* Ends a run: the children are stopped, output and files are flushed, a diagnostic is printed. It returns the exit
 * status without leaving the process; the hand-off from the front end to the program uses it to retire the front
 * end. *OUTCOME is rewritten when a write of standard output or error failed (and no stop signal ended the run): it
 * becomes AGC_FAILED with RUNTIME-INTERNAL and the message "cannot write to standard output" (or error), which is
 * printed, and the status is 1. A caller that decides from the outcome afterwards must read the rewritten one. */
int agc_launch_settle(agc_vm *vm, agc_outcome *outcome);

/* The last step of a process: raises the stop signal that ended the run, if any, or exits with CODE. */
_Noreturn void agc_launch_exit(int code);

/* agc_launch_settle then agc_launch_exit: the one exit path of docs/vm/14-core-invariants.md, 14.4. */
_Noreturn void agc_launch_end(agc_vm *vm, agc_outcome outcome);

#endif
