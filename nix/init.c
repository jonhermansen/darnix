/*
 * Darnix init — portable across x86_64 and arm64 Darwin.
 *
 * Build modes:
 *   -DDARNIX_NOLIBC  static, no libc, raw syscalls (temporary)
 *   (default)        links with libSystem or llvm-libc
 */

#ifdef DARNIX_NOLIBC

#ifdef __x86_64__
#define SYSCALL_CLASS_UNIX (2ULL << 24)
static long syscall3(long num, long a, long b, long c) {
	register long rax __asm__("rax") = num;
	register long rdi __asm__("rdi") = a;
	register long rsi __asm__("rsi") = b;
	register long rdx __asm__("rdx") = c;
	__asm__ volatile("syscall"
	    : "+r"(rax) : "r"(rdi), "r"(rsi), "r"(rdx)
	    : "rcx","r11","memory");
	return rax;
}
#elif defined(__aarch64__)
#define SYSCALL_CLASS_UNIX 0
static long syscall3(long num, long a, long b, long c) {
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x16 __asm__("x16") = num;
	__asm__ volatile("svc #0x80"
	    : "+r"(x0) : "r"(x1), "r"(x2), "r"(x16) : "memory", "cc");
	return x0;
}
#else
#error "Unsupported architecture"
#endif

#define SYS_exit   (SYSCALL_CLASS_UNIX | 1)
#define SYS_write  (SYSCALL_CLASS_UNIX | 4)
#define SYS_getpid (SYSCALL_CLASS_UNIX | 20)
#define SYS_dup2   (SYSCALL_CLASS_UNIX | 90)

typedef unsigned long size_t;
typedef long ssize_t;
typedef int pid_t;

static void _exit(int status) { syscall3(SYS_exit, status, 0, 0); __builtin_unreachable(); }
static ssize_t write(int fd, const void *buf, size_t n) { return syscall3(SYS_write, fd, (long)buf, n); }
static pid_t getpid(void) { return (int)syscall3(SYS_getpid, 0, 0, 0); }
static int dup2(int old, int new) { return (int)syscall3(SYS_dup2, old, new, 0); }

#else

#include <unistd.h>
#include <stdlib.h>

#endif

__attribute__((no_builtin("strlen")))
static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
static void print(const char *m) { write(1, m, slen(m)); }

static int darnix_main(void) {
	if (getpid() == 1) {
		dup2(0, 1);
		dup2(0, 2);
	}

	print("\n");
	print("\033[1;34m  \\\\  \\\\ //\033[0m\n");
	print("\033[1;34m ==\\\\__\\\\/ //\033[0m\n");
	print("\033[1;34m   //   \\\\//\033[0m    \033[1;37mDarnix\033[0m\n");
	print("\033[1;34m ==//     //==\033[0m\n");
	print("\033[1;34m  //\\\\___//\033[0m\n");
	print("\033[1;34m // /\\\\  \\\\==\033[0m\n");
	print("\033[1;34m   // \\\\  \\\\\033[0m\n");
	print("\n");
	print("  Welcome to Darnix\n");

#ifdef __x86_64__
	print("  arch: x86_64\n");
#elif defined(__aarch64__)
	print("  arch: arm64\n");
#endif

	print("\n");
	print("DARNIX BOOT COMPLETE\n");

	if (getpid() == 1) {
		for (;;)
			; /* replaced with nanosleep once llvm-libc is wired up */
	}
	return 0;
}

#ifdef DARNIX_NOLIBC
void _start(void) {
	darnix_main();
	_exit(0);
}
#else
int main(void) {
	return darnix_main();
}
#endif
