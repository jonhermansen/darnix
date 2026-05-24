{ pkgs, inputs, system, buildScriptSrc }:

let
  # Xcode .xip — Apple's URL is gated by Developer auth.
  xcodeXip = pkgs.requireFile {
    name = "Xcode_26.4.1_Apple_silicon.xip";
    hash = "sha256-ydLjr+g/1V9TuzXvJZdBNR8zJ9HxGj9KX7kNXCONtKI=";
    url = "https://download.developer.apple.com/Developer_Tools/Xcode_26.4.1/Xcode_26.4.1_Apple_silicon.xip";
  };

  kdkDmg = pkgs.requireFile {
    name = "Kernel_Debug_Kit_26.4.1_build_25E253.dmg";
    url = "https://download.developer.apple.com/macOS/Kernal_Debug_Kit_26.4.1_build_25E253/Kernel_Debug_Kit_26.4.1_build_25E253.dmg";
    hash = "sha256-23nDOhApwoNTIq0jpJVJSeHAL52WhuwKnBJuYpqzA/M=";
  };

  xcrunShim = pkgs.writeShellScriptBin "xcrun" ''
    : "''${DEVELOPER_DIR:?DEVELOPER_DIR not set}"
    find_tool() {
      for d in \
        "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin" \
        "$DEVELOPER_DIR/usr/bin" \
        "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/bin" \
        "$DEVELOPER_DIR/Platforms/MacOSX.platform/usr/bin"; do
        [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
      done
      command -v "$1" 2>/dev/null && return 0
      echo "xcrun: tool '$1' not found" >&2; return 1
    }
    while [ $# -gt 0 ]; do
      case "$1" in
        -sdk|--sdk)             shift 2 ;;
        -toolchain|--toolchain) shift 2 ;;
        -f|-find|--find)                            shift; find_tool "$1"; exit $? ;;
        --show-sdk-path|-show-sdk-path)             echo "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"; exit 0 ;;
        --show-sdk-version|-show-sdk-version)       echo "26.4"; exit 0 ;;
        --show-sdk-platform-path|-show-sdk-platform-path) echo "$DEVELOPER_DIR/Platforms/MacOSX.platform"; exit 0 ;;
        -*)                     shift ;;
        *)                      break ;;
      esac
    done
    tool=$(find_tool "$1") || exit 1
    shift
    exec "$tool" "$@"
  '';

  plutilShim = pkgs.writeShellScriptBin "plutil" ''
    ${pkgs.python3}/bin/python3 - "$@" <<'PYEOF'
    import sys, plistlib
    args = sys.argv[1:]
    while args and args[0].startswith("-"):
      f = args[0]
      if f in ("-lint", "-s"): args.pop(0)
      elif f == "-convert": args = args[2:]
      elif f == "-o": args = args[2:]
      else: args.pop(0)
    for path in args:
      try:
        with open(path, "rb") as fh: plistlib.load(fh)
      except Exception as e:
        print(f"{path}: {e}", file=sys.stderr); sys.exit(1)
    sys.exit(0)
    PYEOF
  '';

  sysctlShim = pkgs.writeShellScriptBin "sysctl" ''
    case "$*" in
      *hw.physicalcpu*) echo 1 ;;
      *hw.logicalcpu*)  echo 1 ;;
      *hw.memsize*)     echo 1073741824 ;;
      *)                echo 0 ;;
    esac
  '';

  codesignShim = pkgs.writeShellScriptBin "codesign" ''
    file=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -s|--sign)     shift 2 ;;
        -i|--identifier|-r|--requirements|--entitlements|--prefix|--timestamp|-o|--options) shift 2 ;;
        -*)            shift ;;
        *)             file="$1"; shift ;;
      esac
    done
    [ -n "$file" ] || exit 0
    exec ${pkgs.rcodesign}/bin/rcodesign sign "$file"
  '';

  swVersShim = pkgs.writeShellScriptBin "sw_vers" ''
    case "$1" in
      -productName|--productName)       echo "macOS" ;;
      -productVersion|--productVersion) echo "26.4" ;;
      -buildVersion|--buildVersion)     echo "25E253" ;;
      *) echo "ProductName: macOS"; echo "ProductVersion: 26.4"; echo "BuildVersion: 25E253" ;;
    esac
  '';

  xcodeSelectShim = pkgs.writeShellScriptBin "xcode-select" ''
    : "''${DEVELOPER_DIR:?DEVELOPER_DIR not set}"
    case "$1" in
      -p|--print-path) echo "$DEVELOPER_DIR"; exit 0 ;;
      *)               exit 0 ;;
    esac
  '';

  xcode = pkgs.runCommand "xcode-26.4.1" {
    nativeBuildInputs = [ pkgs.xar pkgs.pbzx pkgs.cpio ];
  } ''
    xar -xf ${xcodeXip}
    pbzx -n Content | cpio -i
    mkdir -p $out
    mv Xcode.app $out/
  '';

  kdk = pkgs.runCommand "kdk-26.4.1-25E253" {
    nativeBuildInputs = [ pkgs.p7zip pkgs.xar pkgs.cpio pkgs.pbzx ];
  } ''
    7z x ${kdkDmg}
    xar -xf "Kernel Debug Kit/KernelDebugKit.pkg"
    mkdir -p $out/KDK_26.4.1_25E253.kdk
    (cd $out/KDK_26.4.1_25E253.kdk && pbzx -n $NIX_BUILD_TOP/KDK.pkg/Payload     | cpio -i)
    (cd $out/KDK_26.4.1_25E253.kdk && pbzx -n $NIX_BUILD_TOP/KDK_SDK.pkg/Payload | cpio -i)
  '';

  ctftools = pkgs.stdenv.mkDerivation {
    pname = "ctftools";
    version = "413";
    src = inputs.dtrace-src;
    buildInputs = [ pkgs.zlib ];
    buildPhase = ''
      DTRACE=$(pwd)
      CFLAGS="-w -I$DTRACE/tools/ctfconvert -I$DTRACE/lib/libctf/common -I$DTRACE/lib/libdwarf -I$DTRACE/lib/libelf -I$DTRACE/include -I$DTRACE/compat/opensolaris -I$DTRACE/compat/opensolaris/sys -I$DTRACE/lib/libdwarf/cmplrs -include $DTRACE/compat/opensolaris/darwin_shim.h -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"
      CXXFLAGS="$CFLAGS -std=c++17 -I$DTRACE/include/llvm-ADT -I$DTRACE/include/llvm-Support"

      mkdir -p obj
      echo "Building libelf..."
      for f in $DTRACE/lib/libelf/*.c; do
        cc $CFLAGS -c "$f" -o "obj/elf_$(basename $f .c).o"
      done
      echo "Building libdwarf..."
      for f in $DTRACE/lib/libdwarf/*.c; do
        case $(basename $f) in pro_*) continue;; esac
        cc $CFLAGS -c "$f" -o "obj/dwarf_$(basename $f .c).o"
      done
      echo "Building libctf..."
      for f in $DTRACE/lib/libctf/common/*.c; do
        cc $CFLAGS -c "$f" -o "obj/ctflib_$(basename $f .c).o"
      done
      cc $CFLAGS -c "$DTRACE/compat/opensolaris/darwin_shim.c" -o obj/darwin_shim.o
      echo "Building ctf tools (C)..."
      for f in $DTRACE/tools/ctfconvert/*.c; do
        cc $CFLAGS -c "$f" -o "obj/tool_$(basename $f .c).o"
      done
      echo "Building ctf tools (C++)..."
      for f in $DTRACE/tools/ctfconvert/*.cpp; do
        c++ $CXXFLAGS -c "$f" -o "obj/tool_$(basename $f .cpp).o"
      done

      echo "Linking..."
      cd obj
      LIB_OBJS="$(ls elf_*.o dwarf_*.o ctflib_*.o darwin_shim.o)"
      SHARED="$(ls tool_*.o | grep -v tool_ctfconvert.o | grep -v tool_ctfmerge.o | grep -v tool_dump.o | grep -v tool_compare.o)"
      cc $LIB_OBJS $SHARED tool_ctfconvert.o -lz -lc++ -o ctfconvert
      cc $LIB_OBJS $SHARED tool_ctfmerge.o   -lz -lc++ -o ctfmerge
      cc $LIB_OBJS $SHARED tool_dump.o       -lz -lc++ -o ctfdump
      echo "Done!"
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp ctfconvert ctfmerge ctfdump $out/bin/
    '';
  };

  withLTO = true;

  mkXnu = { arch, machine, label, kernelConfig ? "DEVELOPMENT" }: let
    buildTools = with pkgs; [
      jq git cmake ninja gnumake
      gnugrep gnused gawk gnupatch coreutils curl which findutils gzip pax rcodesign
      perl python3 tcsh bash
      xcrunShim xcodeSelectShim swVersShim sysctlShim codesignShim plutilShim
      darwin.bootstrap_cmds
    ];
  in pkgs.stdenvNoCC.mkDerivation {
    pname   = "xnu-${label}";
    version = "12377.101.15";
    src = buildScriptSrc;

    nativeBuildInputs = buildTools;

    xnu                  = inputs.xnu-src;
    hfs                  = inputs.hfs-src;
    bootstrap_cmds       = inputs.bootstrap_cmds-src;
    dtrace               = inputs.dtrace-src;
    AvailabilityVersions = inputs.AvailabilityVersions-src;
    Libsystem            = inputs.Libsystem-src;
    libplatform          = inputs.libplatform-src;
    libdispatch          = inputs.libdispatch-src;

    configurePhase = ''
      for s in xnu bootstrap_cmds dtrace AvailabilityVersions Libsystem libplatform libdispatch; do
        cp -R "''${!s}"/. "./$s"
        chmod -R u+w "./$s"
      done

      mkdir -p xnu/bsd/hfs xnu/bsd/hfs_encodings
      cp -R "$hfs"/core/*.c "$hfs"/core/*.cpp "$hfs"/core/*.h xnu/bsd/hfs/
      cp -R "$hfs"/hfs_encodings/*.c "$hfs"/hfs_encodings/*.h xnu/bsd/hfs_encodings/
      ln -s hfs xnu/bsd/core

      find . -type f -not -path './.git/*' -print0 \
        | xargs -0 sed -i 's|/usr/bin/env|${pkgs.coreutils}/bin/env|g'

      sed -i \
        -e 's|/bin/cat|${pkgs.coreutils}/bin/cat|g' \
        -e 's|/bin/chmod|${pkgs.coreutils}/bin/chmod|g' \
        -e 's|/bin/cp|${pkgs.coreutils}/bin/cp|g' \
        -e 's|/bin/ln|${pkgs.coreutils}/bin/ln|g' \
        -e 's|/bin/mkdir|${pkgs.coreutils}/bin/mkdir|g' \
        -e 's|/bin/mv|${pkgs.coreutils}/bin/mv|g' \
        -e 's|/bin/pax|${pkgs.pax}/bin/pax|g' \
        -e 's|/bin/pwd|${pkgs.coreutils}/bin/pwd|g' \
        -e 's|/bin/rm |${pkgs.coreutils}/bin/rm |g' \
        -e 's|/bin/rmdir|${pkgs.coreutils}/bin/rmdir|g' \
        -e 's|/bin/sleep|${pkgs.coreutils}/bin/sleep|g' \
        -e 's|/usr/bin/awk|${pkgs.gawk}/bin/awk|g' \
        -e 's|/usr/bin/basename|${pkgs.coreutils}/bin/basename|g' \
        -e 's|/usr/bin/dirname|${pkgs.coreutils}/bin/dirname|g' \
        -e 's|/usr/bin/find|${pkgs.findutils}/bin/find|g' \
        -e 's|/usr/bin/grep|${pkgs.gnugrep}/bin/grep|g' \
        -e 's|/usr/bin/patch|${pkgs.gnupatch}/bin/patch|g' \
        -e 's|/usr/bin/sed|${pkgs.gnused}/bin/sed|g' \
        -e 's|/usr/bin/touch|${pkgs.coreutils}/bin/touch|g' \
        -e 's|/usr/bin/tr|${pkgs.coreutils}/bin/tr|g' \
        -e 's|/usr/bin/xargs|${pkgs.findutils}/bin/xargs|g' \
        -e 's|/usr/bin/xcrun|${xcrunShim}/bin/xcrun|g' \
        -e 's|/usr/bin/codesign|${codesignShim}/bin/codesign|g' \
        -e 's|/usr/sbin/sysctl|${sysctlShim}/bin/sysctl|g' \
        -e 's|/usr/bin/plutil|${plutilShim}/bin/plutil|g' \
        xnu/Makefile xnu/makedefs/MakeInc.cmd xnu/makedefs/MakeInc.def xnu/makedefs/MakeInc.rule xnu/makedefs/MakeInc.top

      sed -i 's|^\(\t.*\)install \$(DATA_INSTALL_FLAGS)|\1$(INSTALL) $(DATA_INSTALL_FLAGS)|' \
        xnu/libkern/libkern/Makefile

      find xnu -type f \( -name "*.sh" -o -name "*.pl" -o -name "*.py" -o -path "*/SETUP/config/doconf" \) -print0 \
        | xargs -0 sed -i \
            -e '1s|^#!/bin/csh|#!${pkgs.tcsh}/bin/tcsh|' \
            -e '1s|^#!/bin/bash|#!${pkgs.bash}/bin/bash|' \
            -e '1s|^#!/bin/sh|#!${pkgs.bash}/bin/sh|' \
            -e '1s|^#!/usr/bin/perl|#!${pkgs.perl}/bin/perl|' \
            -e '1s|^#!/usr/bin/python3|#!${pkgs.python3}/bin/python3|' \
            -e '1s|^#!/usr/bin/env python3|#!${pkgs.python3}/bin/python3|' \
            -e '1s|^#!/usr/bin/env python|#!${pkgs.python3}/bin/python3|' \
            -e '1s|^#!/usr/bin/awk|#!${pkgs.gawk}/bin/awk|'

      sed -i 's|^\(\t.*\)install \$(DATA_INSTALL_FLAGS)|\1$(INSTALL) $(DATA_INSTALL_FLAGS)|' \
        xnu/libkern/libkern/Makefile

      ${pkgs.lib.optionalString (arch == "X86_64") ''
        sed -i '/^LEXT(_start)/{n;s/ARM64_PROLOG/brk\t#0\n\tARM64_PROLOG/}' \
          xnu/osfmk/arm64/start.s
      ''}

      # Enable nos_arm_asm so assembly/low-level source files compile
      # from source instead of using KDK prebuilt objects.
      # nos_arm_pmap is NOT enabled — pmap.c depends on internal Apple
      # headers that aren't in the open-source release.
      sed -i 's/config_darkboot ARM_EXTRAS_BASE/config_darkboot nos_arm_asm ARM_EXTRAS_BASE/' \
        xnu/config/MASTER.arm64.MacOSX

      # Provide empty headers for Apple-internal directories
      # that don't exist in the open-source release
      mkdir -p xnu/osfmk/arm64/tunables xnu/osfmk/arm64/ppl

      # tunables.s: per-SoC register tuning applied at boot.
      # VMAPPLE has no SoC tunables — APPLY_TUNABLES is a no-op.
      cat > xnu/osfmk/arm64/tunables/tunables.s << 'TUNABLES_EOF'
.macro APPLY_TUNABLES
.endmacro
TUNABLES_EOF

      # ppl/sart.h and ppl/uat.h: PPL hardware driver headers.
      # Empty for VMAPPLE — no SART or UAT hardware.
      echo '/* no SART on VMAPPLE */' > xnu/osfmk/arm64/ppl/sart.h
      echo '/* no UAT on VMAPPLE */' > xnu/osfmk/arm64/ppl/uat.h

      # Append Apple-internal cache routines missing from open-source release.
      # These are dcache clean loops called with preemption already disabled.
      cat >> xnu/osfmk/arm64/caches_asm.s << 'CACHES_EOF'

	.text
	.align 2
	.globl EXT(CleanPoC_DcacheRegion_Force_nopreempt)
LEXT(CleanPoC_DcacheRegion_Force_nopreempt)
	dsb		sy
	CLEANPOC_DCACHEREGION
	dsb		sy
	ret

	.text
	.align 2
	.globl EXT(CleanPoC_DcacheRegion_Force_nopreempt_nohid)
LEXT(CleanPoC_DcacheRegion_Force_nopreempt_nohid)
	dsb		sy
	CLEANPOC_DCACHEREGION
	dsb		sy
	ret
CACHES_EOF

      # Remove conf/files entries for closed-source AMCC/CTRR files
      # (source not in Apple's open-source release; CTRR disabled for QEMU)
      sed -i '/amcc_rorgn_ppl\.c\|amcc_rorgn_ppl_amcc\.c\|amcc_rorgn_common\.c\|amcc_rorgn_pv_ctrr\.c/d' \
        xnu/osfmk/conf/files.arm64

      # Virtual platform implementations for symbols that have no
      # open-source equivalent (hardware doesn't exist on QEMU -M virt)
      cat > xnu/osfmk/arm64/vmapple_platform.c << 'VMPLAT_EOF'
#include <mach/vm_types.h>
vm_offset_t ctrr_test_page;
VMPLAT_EOF
      echo 'osfmk/arm64/vmapple_platform.c standard' >> xnu/osfmk/conf/files.arm64

      cat > xnu/pexpert/arm/pe_bootargs.c << 'BOOTARGS_EOF'
#include <pexpert/pexpert.h>
#include <pexpert/boot.h>
#include <string.h>
#define FORCED_BOOT_ARGS " -v debug=0x14e serial=3 keepsyms=1"
static int boot_args_patched = 0;
char *
PE_boot_args(void)
{
	char *cmdline = (char *)((boot_args *)PE_state.bootArgs)->CommandLine;
	if (!boot_args_patched) {
		if (strlen(cmdline) + strlen(FORCED_BOOT_ARGS) < BOOT_LINE_LENGTH) {
			strlcat(cmdline, FORCED_BOOT_ARGS, BOOT_LINE_LENGTH);
		}
		boot_args_patched = 1;
	}
	return cmdline;
}
BOOTARGS_EOF

      mkdir -p fakeroot/usr/local/bin fakeroot/usr/local/libexec fakeroot/usr

      cp ${pkgs.darwin.bootstrap_cmds}/bin/mig          fakeroot/usr/local/bin/mig
      cp ${pkgs.darwin.bootstrap_cmds}/libexec/migcom   fakeroot/usr/local/libexec/migcom
      chmod +w fakeroot/usr/local/bin/mig
      sed -i 's|MIGCC=/nix/store/[^ ]*clang-wrapper[^/]*/bin/clang|MIGCC=${xcode}/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang|' \
        fakeroot/usr/local/bin/mig

      cp AvailabilityVersions/availability.pl fakeroot/usr/local/libexec/availability.pl
      chmod +x fakeroot/usr/local/libexec/availability.pl

      cp -R ${xcode}/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/. fakeroot/usr/
      chmod -R u+w fakeroot/usr

      mkdir -p fakeroot/System/Library/Frameworks/System.framework

      cp ${ctftools}/bin/ctfconvert fakeroot/usr/local/bin/ctfconvert
      cp ${ctftools}/bin/ctfmerge   fakeroot/usr/local/bin/ctfmerge
      cp ${ctftools}/bin/ctfdump    fakeroot/usr/local/bin/ctfdump
      cp ${pkgs.darwin.cctools}/bin/ctf_insert fakeroot/usr/local/bin/ctf_insert
      chmod +x fakeroot/usr/local/bin/ctf*
    '';

    buildPhase = ''
      export DEVELOPER_DIR=${xcode}/Xcode.app/Contents/Developer
      # Trimmed KDK: keep headers + pmap objects, remove objects we compile from source.
      export KDKROOT=$TMPDIR/kdk-trimmed
      cp -R ${kdk}/KDK_26.4.1_25E253.kdk/. $KDKROOT/
      chmod -R u+w $KDKROOT/System/Library/KernelSupport/

      # Remove nos_arm_asm objects from the archive so our source-compiled
      # versions are used instead (they pick up our VMAPPLE.h changes).
      cd $TMPDIR
      mkdir kdk-repack && cd kdk-repack
      ${pkgs.darwin.cctools}/bin/ar x $KDKROOT/System/Library/KernelSupport/lib${machine}.os.${kernelConfig}.a
      rm -f start.o locore.o cswitch.o pcb.o pinst.o caches_asm.o \
            gxf_exceptions.o machine_routines_asm.o machine_routines_apple.o \
            iofilter.o iofilter_asm.o
      rm $KDKROOT/System/Library/KernelSupport/lib${machine}.os.${kernelConfig}.a
      ${pkgs.darwin.cctools}/bin/ar rcs $KDKROOT/System/Library/KernelSupport/lib${machine}.os.${kernelConfig}.a *.o *.cpo 2>/dev/null || \
      ${pkgs.darwin.cctools}/bin/ar rcs $KDKROOT/System/Library/KernelSupport/lib${machine}.os.${kernelConfig}.a *.o
      cd $NIX_BUILD_TOP/source
      export NIX_LIBSYSTEM_PATH=${xcode}/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr
      unset SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS
      export EXTRA_PATH="${pkgs.lib.makeBinPath buildTools}"
      export GNUMAKE="${pkgs.gnumake}/bin/make"
      export KERNEL_CONFIG=${kernelConfig}
      export ARCH_CONFIG=${arch}
      export MACHINE_CONFIG=${machine}
      export MACOS_VERSION=26.4
      export RC_ProjectSourceVersion=12377.101.15
      export HOME=$TMPDIR
      export BUILD_LTO=${if withLTO then "1" else "0"}
      bash ./build.sh
    '';

    installPhase = ''
      mkdir -p $out
      cp -R build/xnu.obj/* $out/
    '';
  };

  xnu-arm64  = mkXnu { arch = "ARM64";  machine = "VMAPPLE"; label = "arm64-vmapple"; };
  xnu-x86_64 = mkXnu { arch = "X86_64"; machine = "NONE";    label = "x86_64";        };

  grubEfi = inputs.grub-src.packages.${system}.efi-x86_64;

  newfs_hfs = pkgs.stdenv.mkDerivation {
    pname = "newfs_hfs";
    version = "715.100.10";
    src = inputs.hfs-src;
    buildInputs = [ pkgs.darwin.libutil ];
    buildPhase = ''
      mkdir -p include/hfs
      ln -s ../../core/hfs_format.h include/hfs/hfs_format.h
      clang -o newfs_hfs.bin \
        -isystem ./include -I./newfs_hfs -I./core \
        -framework CoreFoundation -framework IOKit \
        -lutil \
        -Wno-format -Wno-deprecated-non-prototype \
        newfs_hfs/newfs_hfs.c newfs_hfs/makehfs.c newfs_hfs/hfs_endian.c
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp newfs_hfs.bin $out/bin/newfs_hfs
    '';
  };

  xpwn = pkgs.xpwn.overrideAttrs (old: {
    meta = old.meta // { broken = false; };
    env.NIX_CFLAGS_COMPILE = toString [
      "-fcommon"
      "-Wno-implicit-int"
      "-Wno-incompatible-pointer-types"
      "-Wno-deprecated-declarations"
      "-Wno-format"
      "-Wno-register"
    ];
  });

  bootArgs = "-v debug=0x14e rd=md0 serial=1 -s io=0xff msgbuf=1048576 keepsyms=1 ignore_msrs=1 atm_diagnostic_config=0x100 amfi_get_out_of_my_way=1 cs_enforcement_disable=1";

  initBin = pkgs.runCommand "darnix-init" {
    nativeBuildInputs = [ pkgs.stdenv.cc ];
  } ''
    clang -target x86_64-apple-macos10.15 -arch x86_64 -fno-builtin \
        -nostdlib -static -Wl,-e,__start -Wl,-adhoc_codesign -o init ${./init.c}
    mkdir -p $out
    cp init $out/init
  '';

  rootfs-mockfs = pkgs.runCommand "darnix-rootfs-mockfs" {} ''
    mkdir -p $out
    cp ${initBin}/init $out/rootfs.dmg
  '';

  rootfs-hfs = pkgs.runCommand "darnix-rootfs-hfs" {
    nativeBuildInputs = [ newfs_hfs xpwn ];
  } ''
    dd if=/dev/zero of=rootfs.dmg bs=1M count=8
    newfs_hfs -s -v Darnix -b 4096 rootfs.dmg
    hfsplus rootfs.dmg mkdir /sbin
    hfsplus rootfs.dmg mkdir /dev
    hfsplus rootfs.dmg add ${initBin}/init /sbin/launchd
    hfsplus rootfs.dmg chmod 755 /sbin/launchd
    mkdir -p $out
    cp rootfs.dmg $out/rootfs.dmg
  '';

  esp = pkgs.runCommand "darnix-esp" {
    nativeBuildInputs = [ pkgs.dosfstools pkgs.mtools ];
  } ''
    kernel=${xnu-x86_64}/DEVELOPMENT_X86_64/kernel.development

    cat > grub.cfg << 'GRUBEOF'
set timeout=5
set default=0
menuentry "Darnix (HFS+)" {
    xnu_kernel64 /boot/kernel boot-args="${bootArgs}" --no-devices
    xnu_kextdir /boot/System.kext
    xnu_ramdisk /boot/rootfs-hfs.dmg
    boot
}
menuentry "Darnix (mockfs)" {
    xnu_kernel64 /boot/kernel boot-args="${bootArgs}" --no-devices
    xnu_kextdir /boot/System.kext
    xnu_ramdisk /boot/rootfs-mockfs.dmg
    boot
}
GRUBEOF

    KEXT_ARGS=()
    while IFS= read -r -d "" f; do
      rel="''${f#${xnu-x86_64}/DEVELOPMENT_X86_64/}"
      KEXT_ARGS+=("boot/$rel=$f")
    done < <(find ${xnu-x86_64}/DEVELOPMENT_X86_64/System.kext -type f -print0)

    ${grubEfi}/bin/grub-mkstandalone \
        --format=x86_64-efi \
        --output=BOOTX64.EFI \
        --modules="xnu xnu_uuid part_gpt part_msdos fat hfsplus normal boot configfile" \
        "boot/grub/grub.cfg=grub.cfg" \
        "boot/kernel=$kernel" \
        "boot/rootfs-hfs.dmg=${rootfs-hfs}/rootfs.dmg" \
        "boot/rootfs-mockfs.dmg=${rootfs-mockfs}/rootfs.dmg" \
        "''${KEXT_ARGS[@]}"

    mkfs.fat -C -F 32 esp.img 65536 >/dev/null
    mmd -i esp.img ::/EFI ::/EFI/BOOT
    mcopy -i esp.img BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI

    mkdir -p $out
    cp esp.img $out/esp.img
    cp $kernel $out/kernel.development
  '';

  run-vm = pkgs.writeShellScriptBin "darnix-vm" ''
    set -euo pipefail
    WORKDIR=$(mktemp -d)
    trap "rm -rf $WORKDIR" EXIT

    QEMU=${pkgs.qemu}
    OVMF="$QEMU/share/qemu/edk2-x86_64-code.fd"
    OVMF_VARS="$QEMU/share/qemu/edk2-i386-vars.fd"

    cp "$OVMF_VARS" "$WORKDIR/ovmf-vars.fd"
    chmod u+w "$WORKDIR/ovmf-vars.fd"

    SERIAL_LOG="/tmp/darnix-serial.log"
    SERIAL_ARG="-serial file:$SERIAL_LOG"
    GDB_ARG=""
    for arg in "$@"; do
      case "$arg" in
        --serial) SERIAL_ARG="-serial stdio" ;;
        --gdb)    GDB_ARG="-s -S"; echo "GDB on :1234 — symbol-file ${esp}/kernel.development" ;;
      esac
    done

    if [[ "$SERIAL_ARG" == *"file:"* ]]; then
      rm -f "$SERIAL_LOG"
      touch "$SERIAL_LOG"
      tail -f "$SERIAL_LOG" &
      TAIL_PID=$!
      trap "kill $TAIL_PID 2>/dev/null; rm -rf $WORKDIR" INT TERM EXIT
    fi

    exec "$QEMU/bin/qemu-system-x86_64" \
        -machine q35 -m 4G -smp 1 \
        -cpu Haswell-noTSX,vendor=GenuineIntel,stepping=4 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF" \
        -drive if=pflash,format=raw,file="$WORKDIR/ovmf-vars.fd" \
        -drive file=${esp}/esp.img,format=raw,if=virtio,readonly=on \
        $SERIAL_ARG \
        -display none -monitor none \
        $GDB_ARG \
        -no-reboot
  '';

  arm64-boot = let
    # kernel_phys must have the same offset within a 32MB block as the Mach-O
    # __TEXT vmaddr (0xfffffe0007004000 & 0x1FFFFFF = 0x1004000), because
    # start.s maps with L2 block entries (32MB granularity on 16K pages).
    kernel_phys = "0x41004000";
    stub_phys   = "0x48000000";
    args_phys   = "0x44000000";
    mem_size    = "0x40000000";
  in pkgs.runCommand "darnix-arm64-boot" {
    nativeBuildInputs = [ pkgs.python3 pkgs.darwin.cctools pkgs.stdenv.cc ];
  } ''
    mkdir -p $out
    kernel=${xnu-arm64}/DEVELOPMENT_ARM64_VMAPPLE/kernel.development.vmapple

    python3 ${./macho2bin.py} "$kernel" $out
    ENTRY_OFF=$(cat $out/entry_offset)
    VIRT_BASE=$(cat $out/virt_base)
    BIN_SIZE=$(cat $out/bin_size)

    KERNEL_ENTRY=$(printf "0x%x" $(( ${kernel_phys} + ENTRY_OFF )))
    TOP_OF_KERNEL_DATA=$(printf "0x%x" $(( (${kernel_phys} + BIN_SIZE + 0x3FFFFF) & ~0x3FFFFF )))

    clang -E -P -x assembler-with-cpp \
      -DKERNEL_ENTRY=$KERNEL_ENTRY \
      -DVIRT_BASE=$VIRT_BASE \
      -DKERNEL_PHYS=${kernel_phys} \
      -DARGS_PHYS=${args_phys} \
      -DMEM_SIZE=${mem_size} \
      -DTOP_OF_KERNEL_DATA=$TOP_OF_KERNEL_DATA \
      ${./stub.s} -o stub_pp.s

    as -arch arm64 -o stub.o stub_pp.s
    ld -arch arm64 -e _start -static -pagezero_size 0 -image_base ${stub_phys} -o stub stub.o
    segedit stub -extract __TEXT __text $out/stub.bin

    echo "${kernel_phys}" > $out/kernel_phys
    echo "${stub_phys}" > $out/stub_phys
  '';

  run-vm-arm64 = pkgs.writeShellScriptBin "darnix-vm-arm64" ''
    set -euo pipefail

    KERNEL_PHYS=$(cat ${arm64-boot}/kernel_phys)
    STUB_PHYS=$(cat ${arm64-boot}/stub_phys)

    GDB_ARG=""
    for arg in "$@"; do
      case "$arg" in
        --gdb)    GDB_ARG="-s -S"
                  echo "GDB on :1234"
                  echo "symbol-file ${xnu-arm64}/DEVELOPMENT_ARM64_VMAPPLE/kernel.development.vmapple" ;;
      esac
    done

    exec ${pkgs.qemu}/bin/qemu-system-aarch64 \
        -M virt,highmem=on -accel hvf -cpu host \
        -m 2G -nographic \
        -device loader,file=${arm64-boot}/stub.bin,addr=$STUB_PHYS,force-raw=on,cpu-num=0 \
        -device loader,file=${arm64-boot}/kernel.bin,addr=$KERNEL_PHYS,force-raw=on \
        $GDB_ARG \
        -no-reboot
  '';

in {
  packages = {
    inherit xcode kdk xnu-arm64 xnu-x86_64 esp rootfs-mockfs rootfs-hfs grubEfi newfs_hfs xpwn arm64-boot;
    default = pkgs.runCommand "xnu-all" {} ''
      mkdir -p $out/arm64 $out/x86_64
      cp -R ${xnu-arm64}/* $out/arm64/
      cp -R ${xnu-x86_64}/* $out/x86_64/
    '';
  };
  apps = {
    default = {
      type = "app";
      program = if system == "aarch64-darwin"
        then "${run-vm-arm64}/bin/darnix-vm-arm64"
        else "${run-vm}/bin/darnix-vm";
    };
    x86 = {
      type = "app";
      program = "${run-vm}/bin/darnix-vm";
    };
    arm64 = {
      type = "app";
      program = "${run-vm-arm64}/bin/darnix-vm-arm64";
    };
  };
}
