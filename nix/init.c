/*
 * Darnix init — portable across x86_64 and arm64 Darwin.
 * Statically linked, no libc. Runs as pid 1 in the kernel.
 */

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
static long syscall6(long num, long a, long b, long c, long d, long e, long f) {
	register long rax __asm__("rax") = num;
	register long rdi __asm__("rdi") = a;
	register long rsi __asm__("rsi") = b;
	register long rdx __asm__("rdx") = c;
	register long r10 __asm__("r10") = d;
	register long r8  __asm__("r8")  = e;
	register long r9  __asm__("r9")  = f;
	__asm__ volatile("syscall"
	    : "+r"(rax) : "r"(rdi), "r"(rsi), "r"(rdx), "r"(r10), "r"(r8), "r"(r9)
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
static long syscall6(long num, long a, long b, long c, long d, long e, long f) {
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	register long x16 __asm__("x16") = num;
	__asm__ volatile("svc #0x80"
	    : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x16) : "memory", "cc");
	return x0;
}
#else
#error "Unsupported architecture"
#endif

#ifdef __x86_64__
#define SYS_exit         (SYSCALL_CLASS_UNIX | 1)
#define SYS_read         (SYSCALL_CLASS_UNIX | 3)
#define SYS_write        (SYSCALL_CLASS_UNIX | 4)
#define SYS_open         (SYSCALL_CLASS_UNIX | 5)
#define SYS_reboot       (SYSCALL_CLASS_UNIX | 55)
#define SYS_dup2         (SYSCALL_CLASS_UNIX | 90)
#define SYS_gettimeofday (SYSCALL_CLASS_UNIX | 116)
#define SYS_sysctl       (SYSCALL_CLASS_UNIX | 202)
#define SYS_nanosleep    (SYSCALL_CLASS_UNIX | 240)
#else
#define SYS_exit         1
#define SYS_read         3
#define SYS_write        4
#define SYS_open         5
#define SYS_reboot       55
#define SYS_dup2         90
#define SYS_gettimeofday 116
#define SYS_sysctl       202
#define SYS_nanosleep    240
#endif

#define RB_HALT 0x8

struct timeval  { long tv_sec; long tv_usec; };
struct timespec { long tv_sec; long tv_nsec; };

static void sys_exit(int status) { syscall3(SYS_exit, status, 0, 0); __builtin_unreachable(); }
static long sys_read(int fd, void *buf, unsigned long n) { return syscall3(SYS_read, fd, (long)buf, n); }
static long sys_write(int fd, const void *buf, unsigned long n) { return syscall3(SYS_write, fd, (long)buf, n); }
static int sys_open(const char *path, int flags) { return (int)syscall3(SYS_open, (long)path, flags, 0); }
static int sys_dup2(int old, int new) { return (int)syscall3(SYS_dup2, old, new, 0); }
static void sys_reboot(int howto) { syscall3(SYS_reboot, howto, 0, 0); }
static int sys_gettimeofday(struct timeval *tv) { return (int)syscall3(SYS_gettimeofday, (long)tv, 0, 0); }
static int sys_nanosleep(const struct timespec *req, struct timespec *rem) {
	return (int)syscall3(SYS_nanosleep, (long)req, (long)rem, 0);
}
static int sys_sysctl(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	return (int)syscall6(SYS_sysctl, (long)name, namelen, (long)oldp, (long)oldlenp, 0, 0);
}

__attribute__((no_builtin("strlen")))
static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void print(const char *m) { sys_write(1, m, slen(m)); }

static void print_dec(unsigned long v) {
	char buf[20];
	int i = 0;
	if (v == 0) { print("0"); return; }
	while (v > 0) { buf[i++] = '0' + (v % 10); v /= 10; }
	char out[20];
	for (int j = 0; j < i; j++) out[j] = buf[i - 1 - j];
	sys_write(1, out, i);
}

void _start(void) {
	/* kernel opens /dev/console as fd 0 before exec'ing init */
	sys_dup2(0, 1);
	sys_dup2(0, 2);

	/* /etc/issue */
	print("\033[H\033[2J"); /* clear screen */
	print("\n");
	print("\033[1;34m  \\\\  \\\\ //\033[0m\n");
	print("\033[1;34m ==\\\\__\\\\/ //\033[0m\n");
	print("\033[1;34m   //   \\\\//\033[0m    \033[1;37mDarnix\033[0m\n");
	print("\033[1;34m ==//     //==\033[0m\n");
	print("\033[1;34m  //\\\\___//\033[0m\n");
	print("\033[1;34m // /\\\\  \\\\==\033[0m\n");
	print("\033[1;34m   // \\\\  \\\\\033[0m\n");
	print("\n");

#ifdef __x86_64__
	print("  arch: x86_64\n");
#elif defined(__aarch64__)
	print("  arch: arm64\n");
#endif

	/* kern.version */
	char version[256];
	for (int i = 0; i < 256; i++) version[i] = 0;
	unsigned long vlen = sizeof(version);
	int mib_ver[2] = {1, 4}; /* CTL_KERN, KERN_VERSION */
	if (sys_sysctl(mib_ver, 2, version, &vlen) == 0) {
		print("  ");
		print(version);
		print("\n");
	}

	/* kern.osrelease for the welcome line */
	char osrelease[64];
	for (int i = 0; i < 64; i++) osrelease[i] = 0;
	unsigned long olen = sizeof(osrelease);
	int mib_rel[2] = {1, 2}; /* CTL_KERN, KERN_OSRELEASE */
	sys_sysctl(mib_rel, 2, osrelease, &olen);

	/* boot time */
	struct timeval boottime;
	unsigned long blen = sizeof(boottime);
	int mib_boot[2] = {1, 21}; /* CTL_KERN, KERN_BOOTTIME */
	if (sys_sysctl(mib_boot, 2, &boottime, &blen) == 0) {
		struct timeval now;
		if (sys_gettimeofday(&now) == 0) {
			long elapsed = now.tv_sec - boottime.tv_sec;
			print("  booted in ~");
			print_dec(elapsed);
			print("s\n");
		}
	}

	print("\n");

	/* /etc/issue style welcome */
	print("\033[1;37m<<< Welcome to Darnix ");
	print(osrelease);
	print(" (XNU) - console >>>\033[0m\n");
	print("\n");

	print("DARNIX BOOT COMPLETE\n");

	struct timespec ts = { .tv_sec = 1, .tv_nsec = 0 };
	for (;;)
		sys_nanosleep(&ts, 0);
}
