static void sys_write(int fd, const char *buf, unsigned long len) {
	__asm__ volatile("movq $0x2000004,%%rax\n movl %0,%%edi\n movq %1,%%rsi\n movq %2,%%rdx\n syscall"
	    :: "r"(fd), "r"(buf), "r"(len) : "rax","rdi","rsi","rdx","rcx","r11","memory");
}
static unsigned long slen(const char *s) { unsigned long n=0; while(s[n])n++; return n; }
static void print(const char *m) { sys_write(1,m,slen(m)); }
void _start(void) {
	print("\n\n========================================\n");
	print("  PureDarwin init (pid 1)\n  Kernel booted successfully!\n");
	print("========================================\nSpinning forever.\n");
	for(;;) __asm__ volatile("pause");
}
