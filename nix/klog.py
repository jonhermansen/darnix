"""lldb plugin: read XNU kernel message buffer.

Usage from lldb:
    command script import /path/to/klog.py
    klog <virt_base> <kernel_phys>     # with VA-to-PA translation
    klog                                # direct VA access (x86, or when paging visible to stub)

The generated debug.lldb script calls `klog` with the right values — this
file never needs to know about memory layout.
"""
import lldb, struct, shlex

_virt_base = 0
_kernel_phys = 0

def _va2pa(va):
    if _virt_base == 0:
        return va
    return (va - _virt_base + _kernel_phys) & 0xFFFFFFFFFFFFFFFF

def read_klog(debugger, command, result, internal_dict):
    global _virt_base, _kernel_phys
    args = shlex.split(command)
    if len(args) >= 2:
        _virt_base = int(args[0], 0)
        _kernel_phys = int(args[1], 0)

    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    err = lldb.SBError()

    for sym in target.FindSymbols("_msgbufp"):
        msgbufp_va = sym.GetSymbol().GetStartAddress().GetLoadAddress(target)
        if msgbufp_va != 0xFFFFFFFFFFFFFFFF:
            break
    else:
        print("Cannot find _msgbufp", file=result)
        return

    ptr_data = process.ReadMemory(_va2pa(msgbufp_va), 8, err)
    if err.Fail():
        print("Cannot read msgbufp: " + str(err), file=result)
        return
    msgbuf_va = struct.unpack("<Q", ptr_data)[0]
    if msgbuf_va == 0:
        print("msgbufp is NULL", file=result)
        return

    mbuf = process.ReadMemory(_va2pa(msgbuf_va), 24, err)
    if err.Fail():
        print("Cannot read msgbuf: " + str(err), file=result)
        return
    magic, size, bufx, bufr = struct.unpack("<IIII", mbuf[:16])
    bufc_va = struct.unpack("<Q", mbuf[16:24])[0]

    if magic != 0x063061:
        print("Bad magic 0x%x" % magic, file=result)
        return
    if bufc_va == 0 or size == 0:
        print("Buffer not initialized", file=result)
        return
    if bufx == bufr:
        print("Buffer empty", file=result)
        return

    bufc_pa = _va2pa(bufc_va)
    content = b""
    chunk = 0x1000
    ranges = [(bufr, bufx)] if bufx > bufr else [(bufr, size), (0, bufx)]
    for start, end in ranges:
        for off in range(start, end, chunk):
            rlen = min(chunk, end - off)
            data = process.ReadMemory(bufc_pa + off, rlen, err)
            if err.Fail():
                break
            content += data
    print(content.decode("utf-8", errors="replace"), file=result)

def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f klog.read_klog klog")
    print("klog command loaded — use: klog [<virt_base> <kernel_phys>]")
