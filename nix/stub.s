// XNU boot stub for QEMU -M virt (aarch64, hvf)
//
// Expects assembler defines: KERNEL_ENTRY, VIRT_BASE, KERNEL_PHYS,
//   ARGS_PHYS, MEM_SIZE, TOP_OF_KERNEL_DATA
// These are passed via -D flags from the Nix build.

#define UART 0x09000000

.text
.globl _start
_start:
    // Banner
    mov     x1, #(UART >> 16)
    lsl     x1, x1, #16
    adr     x4, banner
    mov     x6, #0
0:  ldrb    w7, [x4, x6]
    cbz     w7, 1f
    str     w7, [x1]
    add     x6, x6, #1
    b       0b
1:

    // Zero boot_args (2 pages)
    mov     x2, #(ARGS_PHYS >> 16)
    lsl     x2, x2, #16
    mov     x3, #0
    mov     x4, #8192
2:  str     xzr, [x2, x3]
    add     x3, x3, #8
    cmp     x3, x4
    b.lt    2b

    // Revision = 2, Version = 2
    mov     w3, #2
    strh    w3, [x2, #0]
    strh    w3, [x2, #2]

    // virtBase (64-bit)
    movz    x3, #((VIRT_BASE >> 48) & 0xFFFF), lsl #48
    movk    x3, #((VIRT_BASE >> 32) & 0xFFFF), lsl #32
    movk    x3, #((VIRT_BASE >> 16) & 0xFFFF), lsl #16
    movk    x3, #(VIRT_BASE & 0xFFFF)
    str     x3, [x2, #8]

    // physBase
    movz    x3, #((KERNEL_PHYS >> 16) & 0xFFFF), lsl #16
    movk    x3, #(KERNEL_PHYS & 0xFFFF)
    str     x3, [x2, #16]

    // memSize
    movz    x3, #((MEM_SIZE >> 16) & 0xFFFF), lsl #16
    movk    x3, #(MEM_SIZE & 0xFFFF)
    str     x3, [x2, #24]

    // topOfKernelData
    movz    x3, #((TOP_OF_KERNEL_DATA >> 16) & 0xFFFF), lsl #16
    movk    x3, #(TOP_OF_KERNEL_DATA & 0xFFFF)
    str     x3, [x2, #32]

    // machineType = 0
    str     wzr, [x2, #88]

    // deviceTreeP = 0, deviceTreeLength = 0
    str     xzr, [x2, #96]
    str     wzr, [x2, #104]

    // CommandLine
    adr     x4, cmdline
    add     x5, x2, #108
    mov     x6, #0
3:  ldrb    w7, [x4, x6]
    strb    w7, [x5, x6]
    cbz     w7, 4f
    add     x6, x6, #1
    b       3b
4:

    // bootFlags = 0
    str     xzr, [x2, #1136]

    // memSizeActual
    movz    x3, #((MEM_SIZE >> 16) & 0xFFFF), lsl #16
    movk    x3, #(MEM_SIZE & 0xFFFF)
    str     x3, [x2, #1144]

    // Print JUMP
    mov     x1, #(UART >> 16)
    lsl     x1, x1, #16
    adr     x4, jumpmsg
    mov     x6, #0
5:  ldrb    w7, [x4, x6]
    cbz     w7, 6f
    str     w7, [x1]
    add     x6, x6, #1
    b       5b
6:

    // x0 = boot_args, jump to kernel
    mov     x0, #(ARGS_PHYS >> 16)
    lsl     x0, x0, #16
    movz    x1, #((KERNEL_ENTRY >> 16) & 0xFFFF), lsl #16
    movk    x1, #(KERNEL_ENTRY & 0xFFFF)
    br      x1

    .p2align 2
banner:  .asciz "DARNIX STUB\r\n"
jumpmsg: .asciz "JUMP\r\n"
cmdline: .asciz "-v debug=0x14e serial=3 keepsyms=1"
