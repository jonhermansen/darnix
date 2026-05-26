"""
Generate a minimal Apple Device Tree (ADT) for booting XNU on QEMU -M vmapple.

ADT binary format:
  DeviceTreeNode:
    uint32 nProperties
    uint32 nChildren
    properties[nProperties]:
      char   name[32]       // NUL-padded
      uint32 length         // value length in bytes
      byte   value[length]  // padded to 4-byte alignment
    children[nChildren]:
      DeviceTreeNode (recursive)
"""

import struct
import sys

def prop(name, value):
    name_bytes = name.encode()[:31].ljust(32, b'\x00')
    if isinstance(value, str):
        value = value.encode() + b'\x00'
    pad = (4 - len(value) % 4) % 4
    return name_bytes + struct.pack('<I', len(value)) + value + b'\x00' * pad

def node(properties, children=None):
    if children is None:
        children = []
    body = b''
    for p in properties:
        body += p
    for c in children:
        body += c
    return struct.pack('<II', len(properties), len(children)) + body

dram_base = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x70000000
dram_size = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x40000000

cpu0 = node([
    prop('name', 'cpu0'),
    prop('reg', struct.pack('<I', 0)),
    prop('state', 'running'),
    prop('die-id', struct.pack('<I', 0)),
    prop('timebase-frequency', struct.pack('<I', 24000000)),
    prop('bus-frequency', struct.pack('<I', 100000000)),
    prop('clock-frequency', struct.pack('<I', 24000000)),
])

cpus = node([
    prop('name', 'cpus'),
], [cpu0])

memory_map = node([
    prop('name', 'memory-map'),
])

chosen = node([
    prop('name', 'chosen'),
    prop('dram-base', struct.pack('<Q', dram_base)),
    prop('dram-size', struct.pack('<Q', dram_size)),
    prop('random-seed', bytes(range(1, 65))),
], [memory_map])

defaults = node([
    prop('name', 'defaults'),
    prop('serial-device', struct.pack('<I', 1)),
])

# vmapple memory map — soc_base must be nonzero so XNU's serial_init
# takes the device-tree phandle path instead of hardcoding 0x09000000.
soc_base = 0x10000000
uart_addr = 0x20010000
gicd_addr = 0x10000000
gicr_addr = 0x10010000
soc_size  = 0x20000000

uart = node([
    prop('name', 'uart0'),
    prop('compatible', 'arm,pl011'),
    prop('AAPL,phandle', struct.pack('<I', 1)),
    prop('reg', struct.pack('<QQ',
        uart_addr - soc_base, 0x1000)),
])

gic = node([
    prop('name', 'gic'),
    prop('interrupt-controller', 'master'),
    prop('reg', struct.pack('<QQQQ',
        gicd_addr - soc_base, 0x10000,
        gicr_addr - soc_base, 0x400000)),
])

timer = node([
    prop('name', 'timer'),
    prop('device_type', 'timer'),
    prop('reg', struct.pack('<QQ',
        0x20050000 - soc_base, 0x1000)),
])

arm_io = node([
    prop('name', 'arm-io'),
    prop('device_type', 'soc'),
    prop('ranges', struct.pack('<QQQ', 0, soc_base, soc_size)),
], [gic, timer, uart])

root = node([
    prop('name', 'device-tree'),
    prop('target-type', 'vmapple'),
    prop('compatible', 'vmapple'),
], [chosen, cpus, arm_io, defaults])

sys.stdout.buffer.write(root)
