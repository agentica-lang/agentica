/* Copyright 2026 Johanderson Mogollon. Apache License 2.0 (cchecker's license), as the rest of the project (LICENSE).
 * A copy of include/cchecker.h of cchecker 0.2.0, the release that CCHECKER_VERSION of mk/vm-test.mk pins: to move to
 * a new release, replace this file with the one of that release. Only the comments are split to fit vm/'s header rule.
 */
/* Annotations for cchecker, the rule checker for C (https://github.com/agentica-lang/cchecker).
 *
 * The macros expand to something only while cchecker dumps the AST with clang (it defines CCHECKER_AST); in every
 * other build, with any compiler, they are empty. A normal build of a project carries no annotation, and it can still
 * build with gcc, MSVC or tcc. A project that wants an attribute for another tool defines the macros itself.
 */
/*
 *   CC_SHORT                    the function never blocks and does bounded work
 *   CC_BLOCKING                 the function may block
 *   CC_HOT                      the function never allocates and makes no system call
 *   CC_OWNS                     the place owns the memory its pointer points to: a local variable or a parameter
 *                               frees it or hands it on on every path; a function returns an owned pointer; a
 *                               store into a CC_OWNS field (or global) hands it on
 *   CC_FREES                    on a parameter: the function frees what the caller passes there
 *   CC_OWNS_OUT                 on a parameter that points to a pointer (`char **out`): the function may hand an
 *                               owned pointer out to the caller through it (`*out = p`); the caller owns what the
 *                               call left (`take(&p)`)
 *   CC_GC                       on a struct, a union or a typedef: the collector manages its values; a value of the
 *                               type, or a pointer to it, is never stored in memory from malloc or in a static
 *   CC_GC_ALLOC                 the function returns memory that the collector manages, under the same rule
 *   CC_PAIR(set, restore)       in the function, a call of `set` is followed by a call of `restore` on every path;
 *                               on `set` itself, in every function that calls it
 *   CC_NO_SYSCALL_UNDER(lock)   the function makes no system call while `lock` is held; on the field of a lock (or a
 *                               global lock), CC_NO_SYSCALL_UNDER() says it of every function that holds that lock
 *                               and makes it a short lock: taking it is not blocking for CC_SHORT
 *   CC_LOCK_LEVEL(n)            on the field of a lock (or a global lock), n a decimal number: take it only while
 *                               the locks held have a lower level
 *   CC_ACQUIRES(lock)           the function returns with `lock` held, for its caller to release
 *   CC_RELEASES(lock)           the function releases `lock`, which its caller took
 *   CC_NORETURN                 a call of the function never comes back (it jumps out or ends the thread)
 *   CC_MAY_JUMP                 a call of the function may jump out (`longjmp` on an error) or return: the jump is
 *                               a way out of the caller, where the ownership and lock rules check what it holds
 *   CC_ASSUME_SHORT             the function counts as fine for CC_SHORT: the short rule does not walk into it
 *   CC_STOP                     no rule walks into the function: what it calls counts for none of them
 *   CC_IGNORE("CODE", "reason") a finding of the rules on the function is a false positive, for this reason
 *
 * Put an annotation before the declaration, or before the type of a parameter:
 *
 *   CC_SHORT int next_id(void);
 *   void adopt(CC_OWNS char *name);
 *   CC_OWNS char *name = malloc(n);
 *   struct CC_GC object { ... };
 *
 * A lock is an expression of the parameters, or of a global: CC_ACQUIRES(q->mu) on `void lock_queue(struct queue *q)`
 * is the lock `x->mu` for a call `lock_queue(x)`.
 */
#ifndef CCHECKER_H
#define CCHECKER_H

#if defined(__clang__) && defined(CCHECKER_AST)
/* cchecker defines CCHECKER_AST when it dumps the AST: clang 19 leaves the text of `annotate` out of its JSON AST, and
 * keeps the message of `deprecated`. The dump hides the warnings this gives. */
#define CC_ANNOTATE_(text) __attribute__((deprecated("cchecker:" text)))

/* The arguments are kept as written, so `CC_PAIR(mask_signals, restore_signals)` is "pair(mask_signals, ...)". */
#define CC_ANNOTATE_ARGS_(name, ...) CC_ANNOTATE_(name "(" #__VA_ARGS__ ")")
#define CC_SHORT CC_ANNOTATE_("short")
#define CC_BLOCKING CC_ANNOTATE_("blocking")
#define CC_HOT CC_ANNOTATE_("hot")
#define CC_OWNS CC_ANNOTATE_("owns")
#define CC_FREES CC_ANNOTATE_("frees")
#define CC_OWNS_OUT CC_ANNOTATE_("owns_out")
#define CC_GC CC_ANNOTATE_("gc")
#define CC_GC_ALLOC CC_ANNOTATE_("gc_alloc")
#define CC_PAIR(...) CC_ANNOTATE_ARGS_("pair", __VA_ARGS__)
#define CC_NO_SYSCALL_UNDER(...) CC_ANNOTATE_ARGS_("no_syscall_under", __VA_ARGS__)
#define CC_ACQUIRES(...) CC_ANNOTATE_ARGS_("acquires", __VA_ARGS__)
#define CC_RELEASES(...) CC_ANNOTATE_ARGS_("releases", __VA_ARGS__)
#define CC_NORETURN CC_ANNOTATE_("noreturn")
#define CC_MAY_JUMP CC_ANNOTATE_("may_jump")
#define CC_ASSUME_SHORT CC_ANNOTATE_("assume_short")
#define CC_STOP CC_ANNOTATE_("stop")
#define CC_LOCK_LEVEL(...) CC_ANNOTATE_ARGS_("lock_level", __VA_ARGS__)
/* The code and the reason are string literals: `CC_IGNORE("CC-EFFECT-SHORT-BLOCKS", "...")` is "ignore(CODE: ...)". */
#define CC_IGNORE(code, reason) CC_ANNOTATE_("ignore(" code ": " reason ")")
#else
#define CC_SHORT
#define CC_BLOCKING
#define CC_HOT
#define CC_OWNS
#define CC_FREES
#define CC_OWNS_OUT
#define CC_GC
#define CC_GC_ALLOC
#define CC_PAIR(...)
#define CC_NO_SYSCALL_UNDER(...)
#define CC_ACQUIRES(...)
#define CC_RELEASES(...)
#define CC_NORETURN
#define CC_MAY_JUMP
#define CC_ASSUME_SHORT
#define CC_STOP
#define CC_LOCK_LEVEL(...)
#define CC_IGNORE(code, reason)
#endif

#endif
