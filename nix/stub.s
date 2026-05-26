// XNU boot stub for QEMU -M vmapple (aarch64, hvf)
//
// Expects assembler defines: KERNEL_ENTRY, VIRT_BASE, KERNEL_PHYS,
//   ARGS_PHYS, MEM_SIZE, TOP_OF_KERNEL_DATA, ADT_PHYS, ADT_SIZE, UART_BASE
// These are passed via -D flags from the Nix build.

#define UART UART_BASE

// Load a full 64-bit immediate into register.
.macro MOV64 reg, val
    movz    \reg, #((\val >> 48) & 0xFFFF), lsl #48
    movk    \reg, #((\val >> 32) & 0xFFFF), lsl #32
    movk    \reg, #((\val >> 16) & 0xFFFF), lsl #16
    movk    \reg, #(\val & 0xFFFF)
.endm

.text
.globl _start
_start:
    // Banner
    MOV64   x1, UART
    adr     x4, banner
    mov     x6, #0
0:  ldrb    w7, [x4, x6]
    cbz     w7, 1f
    str     w7, [x1]
    add     x6, x6, #1
    b       0b
1:

    // Zero boot_args (2 pages)
    MOV64   x2, ARGS_PHYS
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

    // virtBase
    MOV64   x3, VIRT_BASE
    str     x3, [x2, #8]

    // physBase
    MOV64   x3, KERNEL_PHYS
    str     x3, [x2, #16]

    // memSize
    MOV64   x3, MEM_SIZE
    str     x3, [x2, #24]

    // topOfKernelData
    MOV64   x3, TOP_OF_KERNEL_DATA
    str     x3, [x2, #32]

    // machineType = 0
    str     wzr, [x2, #88]

    // deviceTreeP = ADT_PHYS - KERNEL_PHYS + VIRT_BASE (KVA)
    MOV64   x3, VIRT_BASE
    MOV64   x4, ADT_PHYS
    MOV64   x5, KERNEL_PHYS
    add     x3, x3, x4
    sub     x3, x3, x5
    str     x3, [x2, #96]
    // deviceTreeLength
    mov     w3, #ADT_SIZE
    str     w3, [x2, #104]

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
    MOV64   x3, MEM_SIZE
    str     x3, [x2, #1144]

    // Print JUMP
    MOV64   x1, UART
    adr     x4, jumpmsg
    mov     x6, #0
5:  ldrb    w7, [x4, x6]
    cbz     w7, 6f
    str     w7, [x1]
    add     x6, x6, #1
    b       5b
6:

    // x0 = boot_args, jump to kernel
    MOV64   x0, ARGS_PHYS
    MOV64   x1, KERNEL_ENTRY
    br      x1

    .p2align 2
banner:  .asciz "DARNIX STUB\r\n"
jumpmsg: .asciz "JUMP\r\n"
cmdline: .asciz CMDLINE_STR
