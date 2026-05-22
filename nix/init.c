static int sys_open(const char *path, int flags) {
	int fd;
	__asm__ volatile("movq $0x2000005,%%rax\n movq %1,%%rdi\n movl %2,%%esi\n xorl %%edx,%%edx\n syscall\n movl %%eax,%0"
	    : "=r"(fd) : "r"(path), "r"(flags) : "rax","rdi","rsi","rdx","rcx","r11","memory");
	return fd;
}
static int sys_dup2(int old, int new) {
	int ret;
	__asm__ volatile("movq $0x200005A,%%rax\n movl %1,%%edi\n movl %2,%%esi\n syscall\n movl %%eax,%0"
	    : "=r"(ret) : "r"(old), "r"(new) : "rax","rdi","rsi","rdx","rcx","r11","memory");
	return ret;
}
static void sys_write(int fd, const char *buf, unsigned long len) {
	__asm__ volatile("movq $0x2000004,%%rax\n movl %0,%%edi\n movq %1,%%rsi\n movq %2,%%rdx\n syscall"
	    :: "r"(fd), "r"(buf), "r"(len) : "rax","rdi","rsi","rdx","rcx","r11","memory");
}
static void sys_exit(int status) {
	__asm__ volatile("movq $0x2000001,%%rax\n movl %0,%%edi\n syscall"
	    :: "r"(status) : "rax","rdi","rcx","r11");
}
static int sys_sysctl(int *name, unsigned int namelen, void *oldp, unsigned long *oldlenp) {
	int ret;
	__asm__ volatile(
	    "movq $0x20000CA,%%rax\n"
	    "movq %1,%%rdi\n"
	    "movl %2,%%esi\n"
	    "movq %3,%%rdx\n"
	    "movq %4,%%r10\n"
	    "xorq %%r8,%%r8\n"
	    "xorq %%r9,%%r9\n"
	    "syscall\n"
	    "movl %%eax,%0"
	    : "=r"(ret)
	    : "r"(name), "r"(namelen), "r"(oldp), "r"(oldlenp)
	    : "rax","rdi","rsi","rdx","r10","r8","r9","rcx","r11","memory");
	return ret;
}

static unsigned long slen(const char *s) { unsigned long n=0; while(s[n])n++; return n; }
static void print(const char *m) { sys_write(1,m,slen(m)); }

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
	sys_open("/dev/console", 2);
	sys_dup2(0, 1);
	sys_dup2(0, 2);

	print("\n\n");
	print("\033[38;2;0;210;255m ____    _    ____  _   _ ___ __  __\n");
	print("\033[38;2;0;185;230m|  _ \\  / \\  |  _ \\| \\ | |_ _\\ \\/ /\n");
	print("\033[38;2;0;160;205m| | | |/ _ \\ | |_) |  \\| || | \\  / \n");
	print("\033[38;2;0;135;180m| |_| / ___ \\|  _ <| |\\  || | /  \\ \n");
	print("\033[38;2;0;110;155m|____/_/   \\_\\_| \\_\\_| \\_|___/_/\\_\\\n");
	print("\033[0m\n");

	char version[256];
	for (int i = 0; i < 256; i++) version[i] = 0;
	unsigned long vlen = sizeof(version);
	int mib_ver[2] = {1, 4};
	if (sys_sysctl(mib_ver, 2, version, &vlen) == 0) {
		print("\033[1;37m  ");
		print(version);
		print("\033[0m\n");
	}

	struct { long tv_sec; long tv_usec; } boottime;
	unsigned long blen = sizeof(boottime);
	int mib_boot[2] = {1, 21};
	if (sys_sysctl(mib_boot, 2, &boottime, &blen) == 0) {
		print("\033[1;32m  Booted in ~");
		struct { long tv_sec; long tv_usec; } now;
		__asm__ volatile(
		    "movq $0x2000074,%%rax\n"
		    "movq %0,%%rdi\n"
		    "xorq %%rsi,%%rsi\n"
		    "syscall"
		    :: "r"(&now) : "rax","rdi","rsi","rdx","rcx","r11","memory");
		long elapsed = now.tv_sec - boottime.tv_sec;
		print_dec(elapsed);
		print("s\033[0m\n");
	}

	print("\n\033[5;1;32m  Hello from Nix!\033[0m\n\n");
	for(;;) { __asm__ volatile("pause" ::: "memory"); }
}
