{ pkgs, inputs, system, buildScriptSrc, qemu, llvmLibc }:

# Three independent version axes:
#
#   1. Xcode (toolchain) — compiler, linker, SDK headers.
#      Forward-compatible: newer Xcode builds older kernel source.
#      Update: xcodeXip, xcode derivation name, xcrun --show-sdk-version.
#
#   2. macOS target — the OS release the kernel source is from.
#      Update: sw_vers shim (productVersion, buildVersion), MACOS_VERSION.
#
#   3. XNU source + KDK — kernel source and prebuilt objects. Must match.
#      Update: xnu version, RC_ProjectSourceVersion, KDK dmg/hash/paths.
#      These come from apple-oss-distributions and move together.
#
let
  # -- Version pins (see comment above for update rules) --
  xcodeVersion    = "26.4.1";
  xcodeHash       = "sha256-ydLjr+g/1V9TuzXvJZdBNR8zJ9HxGj9KX7kNXCONtKI=";
  macosVersion    = "26.4";
  macosBuild      = "25E253";
  xnuVersion      = "12377.101.15";
  kdkVersion      = "26.4.1";
  kdkHash         = "sha256-23nDOhApwoNTIq0jpJVJSeHAL52WhuwKnBJuYpqzA/M=";

  kdkName = "KDK_${kdkVersion}_${macosBuild}.kdk";

  # Shared kernel boot arguments — common across all architectures.
  commonBootArgs = "-v debug=0x14f keepsyms=1 -s -enable_kprintf_spam atm_diagnostic_config=0x100 -noprogress io=0xff msgbuf=1048576 amfi_get_out_of_my_way=1 cs_enforcement_disable=1";
  x86BootArgs    = "${commonBootArgs} serial=1 rd=md0 ignore_msrs=1";
  arm64BootArgs  = "${commonBootArgs} serial=3 rd=md0";

  xcodeXip = pkgs.requireFile {
    name = "Xcode_${xcodeVersion}_Apple_silicon.xip";
    hash = xcodeHash;
    url = "https://download.developer.apple.com/Developer_Tools/Xcode_${xcodeVersion}/Xcode_${xcodeVersion}_Apple_silicon.xip";
  };

  kdkDmg = pkgs.requireFile {
    name = "Kernel_Debug_Kit_${kdkVersion}_build_${macosBuild}.dmg";
    url = "https://download.developer.apple.com/macOS/Kernal_Debug_Kit_${kdkVersion}_build_${macosBuild}/Kernel_Debug_Kit_${kdkVersion}_build_${macosBuild}.dmg";
    hash = kdkHash;
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
        --show-sdk-version|-show-sdk-version)       echo "${macosVersion}"; exit 0 ;;
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
      -productVersion|--productVersion) echo "${macosVersion}" ;;
      -buildVersion|--buildVersion)     echo "${macosBuild}" ;;
      *) echo "ProductName: macOS"; echo "ProductVersion: ${macosVersion}"; echo "BuildVersion: ${macosBuild}" ;;
    esac
  '';

  xcodeSelectShim = pkgs.writeShellScriptBin "xcode-select" ''
    : "''${DEVELOPER_DIR:?DEVELOPER_DIR not set}"
    case "$1" in
      -p|--print-path) echo "$DEVELOPER_DIR"; exit 0 ;;
      *)               exit 0 ;;
    esac
  '';

  xcode = pkgs.runCommand "xcode-${xcodeVersion}" {
    nativeBuildInputs = [ pkgs.xar pkgs.pbzx pkgs.cpio ];
  } ''
    xar -xf ${xcodeXip}
    pbzx -n Content | cpio -i
    mkdir -p $out
    mv Xcode.app $out/
  '';

  kdk = pkgs.runCommand "kdk-${kdkVersion}-${macosBuild}" {
    nativeBuildInputs = [ pkgs.p7zip pkgs.xar pkgs.cpio pkgs.pbzx ];
  } ''
    7z x ${kdkDmg}
    xar -xf "Kernel Debug Kit/KernelDebugKit.pkg"
    mkdir -p $out/${kdkName}
    (cd $out/${kdkName} && pbzx -n $NIX_BUILD_TOP/KDK.pkg/Payload     | cpio -i)
    (cd $out/${kdkName} && pbzx -n $NIX_BUILD_TOP/KDK_SDK.pkg/Payload | cpio -i)
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

  mkXnu = { arch, machine, kernelConfig ? "DEVELOPMENT" }: let
    label = pkgs.lib.toLower "${kernelConfig}-${arch}-${machine}";
    buildTools = with pkgs; [
      jq git cmake ninja gnumake
      gnugrep gnused gawk gnupatch coreutils curl which findutils gzip pax rcodesign
      perl python3 tcsh bash
      xcrunShim xcodeSelectShim swVersShim sysctlShim codesignShim plutilShim
      darwin.bootstrap_cmds
    ];
  in pkgs.stdenvNoCC.mkDerivation {
    pname   = "xnu-${label}";
    version = xnuVersion;
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

      # Force C preprocessing on .s files so #if/#include directives work
      sed -i 's|^SFLAGS_GEN = -D__ASSEMBLER__|SFLAGS_GEN = -x assembler-with-cpp -D__ASSEMBLER__|' \
        xnu/makedefs/MakeInc.def

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

      ${pkgs.lib.optionalString (arch == "ARM64") ''
      # Enable nos_arm_asm so assembly/low-level source files compile
      # from source instead of using KDK prebuilt objects.
      # nos_arm_pmap is NOT enabled — pmap.c depends on internal Apple
      # headers that aren't in the open-source release.
      sed -i 's/config_darkboot ARM_EXTRAS_BASE/config_darkboot nos_arm_asm ARM_EXTRAS_BASE/' \
        xnu/config/MASTER.arm64.MacOSX

      # Enable HFS and mockfs in arm64 DEVELOPMENT builds (matches x86_64)
      sed -i 's/FILESYS_DEV =    \[ FILESYS_BASE config_iocount_trace \]/FILESYS_DEV =    [ FILESYS_BASE config_iocount_trace mockfs hfs ]/' \
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
      ''}

      cat > xnu/pexpert/arm/pe_bootargs.c << 'BOOTARGS_EOF'
#include <pexpert/pexpert.h>
#include <pexpert/boot.h>
char *
PE_boot_args(void)
{
	return (char *)((boot_args *)PE_state.bootArgs)->CommandLine;
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
      export KDKROOT=$TMPDIR/kdk-trimmed
      cp -R ${kdk}/${kdkName}/. $KDKROOT/
      chmod -R u+w $KDKROOT/System/Library/KernelSupport/

      ${pkgs.lib.optionalString (arch == "ARM64") ''
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
      ''}
      export NIX_LIBSYSTEM_PATH=${xcode}/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr
      unset SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS
      export EXTRA_PATH="${pkgs.lib.makeBinPath buildTools}"
      export GNUMAKE="${pkgs.gnumake}/bin/make"
      export KERNEL_CONFIG=${kernelConfig}
      export ARCH_CONFIG=${arch}
      export MACHINE_CONFIG=${machine}
      export MACOS_VERSION=${macosVersion}
      export RC_ProjectSourceVersion=${xnuVersion}
      export HOME=$TMPDIR
      export BUILD_LTO=${if withLTO then "1" else "0"}
      bash ./build.sh
    '';

    installPhase = ''
      mkdir -p $out
      cp -R build/xnu.obj/* $out/
    '';
  };

  xnu-arm64  = mkXnu { arch = "ARM64";  machine = "VMAPPLE"; };
  xnu-x86_64 = mkXnu { arch = "X86_64"; machine = "NONE";    };

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

  bootArgs = x86BootArgs;

  mkInitBin = arch: let
    target = if arch == "ARM64" then "arm64-apple-macos" else "x86_64-apple-macos";
  in pkgs.runCommand "darnix-init-${pkgs.lib.toLower arch}" {
    nativeBuildInputs = [ pkgs.llvmPackages.clang pkgs.darwin.cctools ];
  } ''
    mkdir -p $out
    clang -target ${target} -nostdlib -static -Wl,-e,__start \
      -O2 -o $out/init ${./init.c}
  '';

  mkRootfsHfs = arch: let
    initBin = mkInitBin arch;
  in pkgs.runCommand "darnix-rootfs-hfs-${pkgs.lib.toLower arch}" {
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

  mkRootfsMockfs = arch: let
    initBin = mkInitBin arch;
  in pkgs.runCommand "darnix-rootfs-mockfs-${pkgs.lib.toLower arch}" {} ''
    mkdir -p $out
    cp ${initBin}/init $out/rootfs.dmg
  '';

  rootfs-hfs = mkRootfsHfs "X86_64";
  rootfs-mockfs = mkRootfsMockfs "X86_64";

  ramBytes = 4 * 1024 * 1024 * 1024;

  # mkTarget { arch, kernelConfig } → { kernel, boot, run }
  #
  # Produces a complete target: kernel build, boot artifacts (firmware/ESP +
  # debug scripts), and a runner that supports --gdb (launches lldb with
  # symbols, VA→PA translation, and klog).
  mkTarget = { arch, kernelConfig ? "DEVELOPMENT" }: let
    machine = if arch == "ARM64" then "VMAPPLE" else "NONE";
    lc = pkgs.lib.toLower;
    kernel = mkXnu { inherit arch machine kernelConfig; };
    kernelDir = "${kernelConfig}_${arch}"
      + pkgs.lib.optionalString (machine != "NONE") "_${machine}";
    kernelFile = "kernel.${lc kernelConfig}"
      + pkgs.lib.optionalString (machine != "NONE") ".${lc machine}";
    kernelPath = "${kernel}/${kernelDir}/${kernelFile}";
    shortLabel = lc arch
      + pkgs.lib.optionalString (kernelConfig != "DEVELOPMENT")
          ("-" + lc kernelConfig);

    targetRootfsHfs = mkRootfsHfs arch;
    targetRootfsMockfs = mkRootfsMockfs arch;

    boot = if arch == "ARM64" then arm64Boot else x86Boot;

    # ── ARM64 boot: stub firmware + flat kernel + ADT + debug harness ──
    arm64Boot = let
      # vmapple memory map: RAM at 0x70000000, firmware at 0x100000.
      # kernel_phys must have the same offset within a 32MB block as the
      # Mach-O __TEXT vmaddr, because start.s maps with L2 block entries.
      dram_base   = "0x70000000";
      kernel_phys = "0x71004000";
      fw_phys     = "0x00100000";
      args_phys   = "0x78000000";
      adt_phys    = "0x78010000";
      uart_base   = "0x20010000";
      mem_size    = "0x${pkgs.lib.toHexString ramBytes}";
      bootArgs    = arm64BootArgs;
    in pkgs.runCommand "darnix-boot-${shortLabel}" {
      nativeBuildInputs = [ pkgs.python3 pkgs.darwin.cctools pkgs.stdenv.cc ];
    } ''
      mkdir -p $out
      KERNEL_FILE=${kernelPath}
      ROOTFS=${targetRootfsHfs}/rootfs.dmg

      ROOTFS_SIZE=$(wc -c < "$ROOTFS")
      ROOTFS_PAGES=$(( (ROOTFS_SIZE + 4095) / 4096 ))
      ROOTFS_ALIGNED=$(( ROOTFS_PAGES * 4096 ))
      PANIC_SIZE=0x80000
      RAMDISK_BASE=$(printf "0x%x" $(( ${dram_base} + ${mem_size} - PANIC_SIZE - ROOTFS_ALIGNED )))

      python3 ${./macho2bin.py} "$KERNEL_FILE" $out
      python3 ${./mkadt.py} ${dram_base} ${mem_size} "$RAMDISK_BASE" "$ROOTFS_SIZE" > $out/adt.bin
      ADT_SIZE=$(wc -c < $out/adt.bin)

      ENTRY_OFF=$(cat $out/entry_offset)
      VIRT_BASE=$(cat $out/virt_base)
      BIN_SIZE=$(cat $out/bin_size)

      KERNEL_ENTRY=$(printf "0x%x" $(( ${kernel_phys} + ENTRY_OFF )))
      ADT_END=$(( ${adt_phys} + ADT_SIZE ))
      KERNEL_END=$(( ${kernel_phys} + BIN_SIZE ))
      HIGHEST=$(( ADT_END > KERNEL_END ? ADT_END : KERNEL_END ))
      TOP_OF_KERNEL_DATA=$(printf "0x%x" $(( (HIGHEST + 0x3FFFFF) & ~0x3FFFFF )))

      clang -E -P -x assembler-with-cpp \
        -DKERNEL_ENTRY=$KERNEL_ENTRY \
        -DVIRT_BASE=$VIRT_BASE \
        -DKERNEL_PHYS=${kernel_phys} \
        -DARGS_PHYS=${args_phys} \
        -DADT_PHYS=${adt_phys} \
        -DADT_SIZE=$ADT_SIZE \
        -DMEM_SIZE=${mem_size} \
        -DTOP_OF_KERNEL_DATA=$TOP_OF_KERNEL_DATA \
        -DUART_BASE=${uart_base} \
        '-DCMDLINE_STR="${bootArgs}"' \
        ${./stub.s} -o stub_pp.s

      as -arch arm64 -o stub.o stub_pp.s
      ld -arch arm64 -e _start -static -pagezero_size 0 -image_base ${fw_phys} -o stub stub.o
      segedit stub -extract __TEXT __text $out/fw.bin

      cp "$ROOTFS" $out/rootfs.dmg

      echo "${kernel_phys}" > $out/kernel_phys
      echo "${adt_phys}" > $out/adt_phys
      echo "$RAMDISK_BASE" > $out/ramdisk_phys

      cat > $out/debug.lldb << DBEOF
target create $KERNEL_FILE
command script import ${./klog.py}
settings set plugin.process.gdb-remote.packet-timeout 10
gdb-remote localhost:4321
breakpoint set -a $KERNEL_ENTRY -N kernel_entry
klog $VIRT_BASE ${kernel_phys}
DBEOF
    '';

    # ── X86_64 boot: GRUB EFI image + debug script ──
    x86Boot = pkgs.runCommand "darnix-boot-${shortLabel}" {
      nativeBuildInputs = [ pkgs.dosfstools pkgs.mtools ];
    } ''
      KERNEL_FILE=${kernelPath}

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
        rel="''${f#${kernel}/${kernelDir}/}"
        KEXT_ARGS+=("boot/$rel=$f")
      done < <(find ${kernel}/${kernelDir}/System.kext -type f -print0)

      ${grubEfi}/bin/grub-mkstandalone \
          --format=x86_64-efi \
          --output=BOOTX64.EFI \
          --modules="xnu xnu_uuid part_gpt part_msdos fat hfsplus normal boot configfile" \
          "boot/grub/grub.cfg=grub.cfg" \
          "boot/kernel=$KERNEL_FILE" \
          "boot/rootfs-hfs.dmg=${targetRootfsHfs}/rootfs.dmg" \
          "boot/rootfs-mockfs.dmg=${targetRootfsMockfs}/rootfs.dmg" \
          "''${KEXT_ARGS[@]}"

      mkfs.fat -C -F 32 esp.img 65536 >/dev/null
      mmd -i esp.img ::/EFI ::/EFI/BOOT
      mcopy -i esp.img BOOTX64.EFI ::/EFI/BOOT/BOOTX64.EFI

      mkdir -p $out
      cp esp.img $out/esp.img
      cp $KERNEL_FILE $out/${kernelFile}

      cat > $out/debug.lldb << DBEOF
target create $out/${kernelFile}
command script import ${./klog.py}
settings set plugin.process.gdb-remote.packet-timeout 10
gdb-remote localhost:4321
klog
DBEOF
    '';

    # ── Arch-specific fragments for the shared run script ──
    bootSetup = if arch == "ARM64" then ''
      KERNEL_PHYS=$(cat ${boot}/kernel_phys)
      ADT_PHYS=$(cat ${boot}/adt_phys)
      RAMDISK_PHYS=$(cat ${boot}/ramdisk_phys)
      dd if=/dev/zero of="$WORKDIR/aux.img" bs=1M count=1 2>/dev/null
      dd if=/dev/zero of="$WORKDIR/root.img" bs=1M count=1 2>/dev/null
    '' else ''
      OVMF="${qemu}/share/qemu/edk2-x86_64-code.fd"
      OVMF_VARS="${qemu}/share/qemu/edk2-i386-vars.fd"
      cp "$OVMF_VARS" "$WORKDIR/ovmf-vars.fd"
      chmod u+w "$WORKDIR/ovmf-vars.fd"
      SERIAL_LOG="/tmp/darnix-serial.log"
      SERIAL_ARG="-serial file:$SERIAL_LOG"
    '';

    qemuArgsDef = if arch == "ARM64" then ''
      QEMU_BIN=${qemu}/bin/qemu-system-aarch64
      QEMU_ARGS=(
        -M vmapple -accel hvf
        -m ${toString ramBytes}B -nographic
        -bios ${boot}/fw.bin
        -pflash "$WORKDIR/aux.img"
        -drive "file=$WORKDIR/root.img,if=pflash,format=raw"
        -device "loader,file=${boot}/kernel.bin,addr=$KERNEL_PHYS,force-raw=on"
        -device "loader,file=${boot}/adt.bin,addr=$ADT_PHYS,force-raw=on"
        -device "loader,file=${boot}/rootfs.dmg,addr=$RAMDISK_PHYS,force-raw=on"
        -no-reboot
      )
    '' else ''
      QEMU_BIN=${qemu}/bin/qemu-system-x86_64
      QEMU_ARGS=(
        -machine q35 -m ${toString ramBytes}B -smp 1
        -cpu "Haswell-noTSX,vendor=GenuineIntel,stepping=4"
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF"
        -drive "if=pflash,format=raw,file=$WORKDIR/ovmf-vars.fd"
        -drive "file=${boot}/esp.img,format=raw,if=virtio,readonly=on"
        $SERIAL_ARG
        -display none -monitor none
        -no-reboot
      )
    '';

    preExec = if arch == "X86_64" then ''
      if [[ "$SERIAL_ARG" == *"file:"* ]]; then
        rm -f "$SERIAL_LOG"
        touch "$SERIAL_LOG"
        tail -f "$SERIAL_LOG" &
        TAIL_PID=$!
        trap "kill $TAIL_PID 2>/dev/null; rm -rf $WORKDIR" INT TERM EXIT
      fi
    '' else "";

    # ── Runner: shared debug logic, arch-specific QEMU invocation ──
    run = pkgs.writeShellScriptBin "darnix-run" ''
      set -euo pipefail
      WORKDIR=$(mktemp -d)
      trap "rm -rf $WORKDIR" EXIT

      ${bootSetup}

      DEBUG=0
      for arg in "$@"; do
        case "$arg" in
          --gdb)    DEBUG=1 ;;
          --serial) SERIAL_ARG="-serial stdio" ;;
        esac
      done

      ${if arch == "X86_64" then ''
      if [ "$DEBUG" -eq 1 ]; then SERIAL_ARG="-serial file:$SERIAL_LOG"; fi
      '' else ""}
      ${qemuArgsDef}

      if [ "$DEBUG" -eq 1 ]; then
        QEMU_ARGS+=(-gdb tcp::4321 -S)
        "$QEMU_BIN" "''${QEMU_ARGS[@]}" &
        QEMU_PID=$!
        trap "kill $QEMU_PID 2>/dev/null; rm -rf $WORKDIR" EXIT INT TERM
        sleep 0.5
        lldb -s ${boot}/debug.lldb
      else
        ${preExec}
        exec "$QEMU_BIN" "''${QEMU_ARGS[@]}"
      fi
    '';

    testBoot = pkgs.writeShellScriptBin "darnix-test-boot" ''
      export PATH="${pkgs.coreutils}/bin:$PATH"
      set -euo pipefail
      WORKDIR=$(mktemp -d)
      trap "rm -rf $WORKDIR" EXIT
      LOGFILE="/tmp/darnix-boot-${shortLabel}.txt"
      echo "=== Darnix boot test: ${shortLabel} ==="

      ${bootSetup}
      ${if arch == "X86_64" then ''SERIAL_ARG="-serial stdio"'' else ""}
      ${qemuArgsDef}

      "$QEMU_BIN" "''${QEMU_ARGS[@]}" > "$LOGFILE" 2>&1 &
      QEMU_PID=$!
      trap "kill $QEMU_PID 2>/dev/null; rm -rf $WORKDIR" EXIT

      while kill -0 $QEMU_PID 2>/dev/null; do
        if grep -q "DARNIX BOOT COMPLETE" "$LOGFILE" 2>/dev/null; then
          kill $QEMU_PID 2>/dev/null
          break
        fi
        sleep 1
      done
      wait $QEMU_PID 2>/dev/null || true

      PASS=0
      FAIL=0
      check() {
        if grep -q "$2" "$LOGFILE"; then
          echo "  PASS: $1"
          PASS=$((PASS + 1))
        else
          echo "  FAIL: $1"
          FAIL=$((FAIL + 1))
        fi
      }

      check "kernel version"       "Darwin Kernel Version"
      check "HFS mount"            "hfs: mounted Darnix"
      check "BSD root"             "BSD root: md0"
      check "init loaded"          "load_init_program"
      check "console opened"       "opened /dev/console"
      check "Darnix banner"        "Welcome to Darnix"
      check "boot complete"       "DARNIX BOOT COMPLETE"
      check "arch: ${if arch == "ARM64" then "arm64" else "x86_64"}" \
            "arch: ${if arch == "ARM64" then "arm64" else "x86_64"}"

      echo ""
      UNAME=$(grep "Darwin Kernel Version" "$LOGFILE" | head -1 | sed 's/.*\(Darwin Kernel Version [0-9.]*\).*/\1/')
      echo "  uname: $UNAME"
      echo ""
      echo "=== Results: $PASS passed, $FAIL failed ==="
      echo "  log: $LOGFILE"

      if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo "=== Last 30 lines ==="
        tail -30 "$LOGFILE"
        exit 1
      fi
    '';

  in { inherit kernel boot run testBoot; };

  targets = {
    arm64  = mkTarget { arch = "ARM64"; };
    x86_64 = mkTarget { arch = "X86_64"; };
  };

in {
  packages = {
    inherit xcode kdk qemu grubEfi newfs_hfs xpwn;
    inherit rootfs-mockfs rootfs-hfs;
    xnu-arm64  = targets.arm64.kernel;
    xnu-x86_64 = targets.x86_64.kernel;
    boot-arm64  = targets.arm64.boot;
    boot-x86_64 = targets.x86_64.boot;
    run-arm64  = targets.arm64.run;
    run-x86_64 = targets.x86_64.run;
    test-boot-arm64  = targets.arm64.testBoot;
    test-boot-x86_64 = targets.x86_64.testBoot;
    default = targets.arm64.run;
  };
  apps = {
    default = {
      type = "app";
      program = if system == "aarch64-darwin"
        then "${targets.arm64.run}/bin/darnix-run"
        else "${targets.x86_64.run}/bin/darnix-run";
    };
    arm64 = {
      type = "app";
      program = "${targets.arm64.run}/bin/darnix-run";
    };
    x86_64 = {
      type = "app";
      program = "${targets.x86_64.run}/bin/darnix-run";
    };
    test-boot-arm64 = {
      type = "app";
      program = "${targets.arm64.testBoot}/bin/darnix-test-boot";
    };
    test-boot-x86_64 = {
      type = "app";
      program = "${targets.x86_64.testBoot}/bin/darnix-test-boot";
    };
  };
  checks = {
    boot-arm64  = targets.arm64.testBoot;
    boot-x86_64 = targets.x86_64.testBoot;
  };
}
