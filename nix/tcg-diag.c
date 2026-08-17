/*
 * TCG diagnostic — isolate which 32-bit instruction causes the hang.
 * Runs as pid 1 under XNU in QEMU TCG.
 *
 * Tests sysctl(CTL_KERN, KERN_VERSION) with different instruction
 * combinations to find which 32-bit vs 64-bit variant triggers the bug.
 */

#define SYSCALL_CLASS_UNIX (2ULL << 24)
#define SYS_exit  (SYSCALL_CLASS_UNIX | 1)
#define SYS_write (SYSCALL_CLASS_UNIX | 4)
#define SYS_dup2  (SYSCALL_CLASS_UNIX | 90)
#define SYS_sysctl (SYSCALL_CLASS_UNIX | 202)

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

static void sys_exit(int code) { syscall3(SYS_exit, code, 0, 0); __builtin_unreachable(); }
static void sys_write(int fd, const void *buf, unsigned long n) { syscall3(SYS_write, fd, (long)buf, n); }
static void sys_dup2(int a, int b) { syscall3(SYS_dup2, a, b, 0); }

__attribute__((no_builtin("strlen")))
static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void print(const char *m) { sys_write(1, m, slen(m)); }

static void print_hex64(unsigned long v) {
	char buf[19] = "0x";
	const char *hex = "0123456789abcdef";
	for (int i = 0; i < 16; i++)
		buf[2+i] = hex[(v >> (60 - i*4)) & 0xf];
	buf[18] = 0;
	sys_write(1, buf, 18);
}

/*
 * Variant A: all 64-bit (known working baseline)
 *   movq $imm, %rax / xorq %r8, %r8 / xorq %r9, %r9
 */
static int sysctl_all64(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	int ret;
	__asm__ volatile(
	    "movq $0x20000CA,%%rax\n\t"
	    "movq %1,%%rdi\n\t"
	    "movl %2,%%esi\n\t"
	    "movq %3,%%rdx\n\t"
	    "movq %4,%%r10\n\t"
	    "xorq %%r8,%%r8\n\t"
	    "xorq %%r9,%%r9\n\t"
	    "syscall\n\t"
	    "movl %%eax,%0"
	    : "=r"(ret)
	    : "r"(name), "r"(namelen), "r"(oldp), "r"(oldlenp)
	    : "rax","rdi","rsi","rdx","r10","r8","r9","rcx","r11","memory");
	return ret;
}

/*
 * Variant B: only xorl on r8/r9 (isolate xorl %r8d)
 *   movq $imm, %rax / xorl %r8d, %r8d / xorl %r9d, %r9d
 */
static int sysctl_xorl_only(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	int ret;
	__asm__ volatile(
	    "movq $0x20000CA,%%rax\n\t"
	    "movq %1,%%rdi\n\t"
	    "movl %2,%%esi\n\t"
	    "movq %3,%%rdx\n\t"
	    "movq %4,%%r10\n\t"
	    "xorl %%r8d,%%r8d\n\t"
	    "xorl %%r9d,%%r9d\n\t"
	    "syscall\n\t"
	    "movl %%eax,%0"
	    : "=r"(ret)
	    : "r"(name), "r"(namelen), "r"(oldp), "r"(oldlenp)
	    : "rax","rdi","rsi","rdx","r10","r8","r9","rcx","r11","memory");
	return ret;
}

/*
 * Variant C: only movl for syscall number (isolate movl $imm, %eax)
 *   movl $imm, %eax / xorq %r8, %r8 / xorq %r9, %r9
 */
static int sysctl_movl_only(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	int ret;
	__asm__ volatile(
	    "movl $0x20000CA,%%eax\n\t"
	    "movq %1,%%rdi\n\t"
	    "movl %2,%%esi\n\t"
	    "movq %3,%%rdx\n\t"
	    "movq %4,%%r10\n\t"
	    "xorq %%r8,%%r8\n\t"
	    "xorq %%r9,%%r9\n\t"
	    "syscall\n\t"
	    "movl %%eax,%0"
	    : "=r"(ret)
	    : "r"(name), "r"(namelen), "r"(oldp), "r"(oldlenp)
	    : "rax","rdi","rsi","rdx","r10","r8","r9","rcx","r11","memory");
	return ret;
}

/*
 * Variant D: only xorl on r8 (not r9)
 *   movq $imm, %rax / xorl %r8d, %r8d / xorq %r9, %r9
 */
static int sysctl_xorl_r8_only(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	int ret;
	__asm__ volatile(
	    "movq $0x20000CA,%%rax\n\t"
	    "movq %1,%%rdi\n\t"
	    "movl %2,%%esi\n\t"
	    "movq %3,%%rdx\n\t"
	    "movq %4,%%r10\n\t"
	    "xorl %%r8d,%%r8d\n\t"
	    "xorq %%r9,%%r9\n\t"
	    "syscall\n\t"
	    "movl %%eax,%0"
	    : "=r"(ret)
	    : "r"(name), "r"(namelen), "r"(oldp), "r"(oldlenp)
	    : "rax","rdi","rsi","rdx","r10","r8","r9","rcx","r11","memory");
	return ret;
}

/*
 * Variant E: only xorl on r9 (not r8)
 *   movq $imm, %rax / xorq %r8, %r8 / xorl %r9d, %r9d
 */
static int sysctl_xorl_r9_only(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	int ret;
	__asm__ volatile(
	    "movq $0x20000CA,%%rax\n\t"
	    "movq %1,%%rdi\n\t"
	    "movl %2,%%esi\n\t"
	    "movq %3,%%rdx\n\t"
	    "movq %4,%%r10\n\t"
	    "xorq %%r8,%%r8\n\t"
	    "xorl %%r9d,%%r9d\n\t"
	    "syscall\n\t"
	    "movl %%eax,%0"
	    : "=r"(ret)
	    : "r"(name), "r"(namelen), "r"(oldp), "r"(oldlenp)
	    : "rax","rdi","rsi","rdx","r10","r8","r9","rcx","r11","memory");
	return ret;
}

/*
 * Variant F: register constraints (what the compiler generates)
 */
static int sysctl_constraint(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	register long rax __asm__("rax") = SYS_sysctl;
	register long rdi __asm__("rdi") = (long)name;
	register long rsi __asm__("rsi") = (long)namelen;
	register long rdx __asm__("rdx") = (long)oldp;
	register long r10 __asm__("r10") = (long)oldlenp;
	register long r8  __asm__("r8")  = 0;
	register long r9  __asm__("r9")  = 0;
	__asm__ volatile("syscall"
	    : "+r"(rax) : "r"(rdi), "r"(rsi), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
	    : "rcx","r11","memory");
	return (int)rax;
}

/*
 * Variant G: read r8 value after xorl to check zero-extension
 */
static unsigned long check_xorl_r8(void) {
	unsigned long val;
	__asm__ volatile(
	    "movq $0xDEADBEEFCAFEBABE,%%r8\n\t"
	    "xorl %%r8d,%%r8d\n\t"
	    "movq %%r8,%0"
	    : "=r"(val) : : "r8");
	return val;
}

static unsigned long check_xorq_r8(void) {
	unsigned long val;
	__asm__ volatile(
	    "movq $0xDEADBEEFCAFEBABE,%%r8\n\t"
	    "xorq %%r8,%%r8\n\t"
	    "movq %%r8,%0"
	    : "=r"(val) : : "r8");
	return val;
}

static unsigned long check_movl_eax(void) {
	unsigned long val;
	__asm__ volatile(
	    "movq $0xDEADBEEFCAFEBABE,%%rax\n\t"
	    "movl $0x20000CA,%%eax\n\t"
	    "movq %%rax,%0"
	    : "=r"(val) : : "rax");
	return val;
}

static void do_test(const char *label,
    int (*fn)(int*, unsigned int, void*, unsigned long*)) {
	char version[256];
	for (int i = 0; i < 256; i++) version[i] = 0;
	unsigned long vlen = 256;
	int mib[2] = {1, 4}; /* CTL_KERN, KERN_VERSION */

	print("  test ");
	print(label);
	print(": ");
	int ret = fn(mib, 2, version, &vlen);
	if (ret == 0) {
		print("OK (");
		/* print first 40 chars of version */
		unsigned long n = vlen > 40 ? 40 : vlen;
		sys_write(1, version, n);
		print("...)\n");
	} else {
		print("FAIL ret=");
		print_hex64((unsigned long)ret);
		print("\n");
	}
}

void _start(void) {
	sys_dup2(0, 1);
	sys_dup2(0, 2);

	print("\n=== TCG instruction diagnostic ===\n\n");

	/* First: check zero-extension directly */
	print("  xorq r8 check: ");
	print_hex64(check_xorq_r8());
	print(" (expect 0)\n");

	print("  xorl r8d check: ");
	print_hex64(check_xorl_r8());
	print(" (expect 0)\n");

	print("  movl eax check: ");
	print_hex64(check_movl_eax());
	print(" (expect 0x00000000020000ca)\n");

	print("\n");

	/* Then: test each sysctl variant */
	do_test("A: all-64bit     ", sysctl_all64);
	do_test("C: movl-eax-only ", sysctl_movl_only);
	do_test("E: xorl-r9-only  ", sysctl_xorl_r9_only);
	do_test("D: xorl-r8-only  ", sysctl_xorl_r8_only);
	do_test("B: xorl-r8r9     ", sysctl_xorl_only);
	do_test("F: constraints   ", sysctl_constraint);

	print("\n=== ALL TESTS PASSED ===\n");
	sys_exit(0);
}
