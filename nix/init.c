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
static unsigned long slen(const char *s) { unsigned long n=0; while(s[n])n++; return n; }
static void print(const char *m) { sys_write(1,m,slen(m)); }
void _start(void) {
	sys_open("/dev/console", 2 /* O_RDWR */);
	sys_dup2(0, 1);
	sys_dup2(0, 2);
	print("\n\n");
	print("\033[1;36m");
	print(" ____    _    ____  _   _ _____  __\n");
	print("|  _ \\  / \\  |  _ \\| \\ | |_ _\\ \\/ /\n");
	print("| | | |/ _ \\ | |_) |  \\| || | \\  / \n");
	print("| |_| / ___ \\|  _ <| |\\  || | /  \\ \n");
	print("|____/_/   \\_\\_| \\_\\_| \\_|___/_/\\_\\\n");
	print("\033[0m\n");
	print("\033[5;1;32m");
	print("  Hello from Nix! XNU kernel booted successfully.\033[0m\n\n");
	for(;;) { __asm__ volatile("pause" ::: "memory"); }
}
