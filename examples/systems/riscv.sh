# This is an example Gentoo build to try RISC-V on an emulator.  There are some
# things that still need to be implemented in upstream projects, particularly
# around UEFI support.  Secure Boot cannot be enforced with the current setup.

options+=(
        [arch]=riscv64   # Target RISC-V emulators.
        [distro]=gentoo  # Use Gentoo to build this image from source.
        [executable]=1   # Generate a VM image for fast testing.
        [bootable]=1     # Build a kernel for this system.
        [networkd]=1     # Let systemd manage the network configuration.
        [secureboot]=    # This is unused until systemd-boot supports RISC-V.
        [uefi]=1         # This is for hacking purposes only.
        [verity]=1       # Prevent the file system from being modified.
)

packages+=(
        # Utilities
        app-arch/cpio
        app-arch/tar
        app-arch/unzip
        app-shells/bash
        dev-util/strace
        dev-vcs/git
        sys-apps/diffutils
        sys-apps/file
        sys-apps/findutils
        sys-apps/gawk
        sys-apps/grep
        sys-apps/kbd
        sys-apps/less
        sys-apps/man-pages
        sys-apps/sed
        sys-apps/which
        sys-devel/patch
        sys-process/lsof
        sys-process/procps
        ## Accounts
        app-admin/sudo
        sys-apps/shadow
        ## Network
        net-firewall/iptables
        net-misc/openssh
        net-misc/wget
        sys-apps/iproute2

        # Disks
        net-fs/sshfs
        sys-fs/cryptsetup
        sys-fs/e2fsprogs
)

function initialize_buildroot() {
        # Build a static RISC-V QEMU in case the host system's QEMU is too old.
        packages_buildroot+=(app-emulation/qemu)
        echo app-emulation/qemu >> "$buildroot/etc/portage/package.accept_keywords/qemu.conf"
        $cat << 'EOF' >> "$buildroot/etc/portage/package.use/qemu.conf"
app-emulation/qemu -* fdt pin-upstream-blobs python_targets_python3_7 qemu_softmmu_targets_riscv64 qemu_user_targets_riscv64 static static-user
dev-libs/glib static-libs
dev-libs/libffi static-libs
dev-libs/libpcre static-libs
dev-libs/libxml2 static-libs
sys-apps/dtc static-libs
sys-apps/util-linux static-libs
sys-libs/zlib static-libs
x11-libs/pixman static-libs
EOF

        # Build RISC-V UEFI GRUB for bootloader testing.
        packages_buildroot+=(sys-boot/grub)
        $curl -L https://lists.gnu.org/archive/mbox/grub-devel/2020-04 > "$output/grub.mbox"
        test x$($sha256sum "$output/grub.mbox" | $sed -n '1s/ .*//p') = \
            x32d142f8af7a0d4c1bf3cb0455e8cb9b4107125a04678da0f471044d90f28137
        $mkdir -p "$buildroot/etc/portage/patches/sys-boot/grub"
        local -i p ; for p in 1 2 3
        do $sed -n "/t:[^:]*RFT $p/,/^2.25/p" "$output/grub.mbox"
        done > "$buildroot/etc/portage/patches/sys-boot/grub/riscv-uefi.patch"
        $rm -f "$output/grub.mbox"

        # Patch UEFI stub support into Linux 5.7.
        $mkdir -p "$buildroot/etc/portage/patches/sys-kernel/gentoo-sources"
        $curl -L > "$buildroot/etc/portage/patches/sys-kernel/gentoo-sources/riscv-uefi.patch" \
            https://github.com/atishp04/linux/compare/ae83d0b416db002fe95601e7f97f64b59514d936...919538d7e19e085ee376f5d2300e14d8e6345218.patch
        test x$($sha256sum "$buildroot/etc/portage/patches/sys-kernel/gentoo-sources/riscv-uefi.patch" | $sed -n '1s/ .*//p') = \
            x014245400e9c839d1a8fbcbbd69ef97791c397c304102361bcbdceb7b0f1202b
}

function customize_buildroot() {
        local -r portage="$buildroot/usr/${options[host]}/etc/portage"

        # Packages just aren't keyworded enough, so accept anything stabilized.
        echo 'ACCEPT_KEYWORDS="*"' >> "$portage/make.conf"

        # Disable broken unstable packages.
        echo '>=dev-libs/libgpg-error-1.38' >> "$portage/package.mask/gnupg.conf"
        echo '>=sys-devel/gcc-10' >> "$portage/package.mask/gcc.conf"

        # Work around the broken aclocal path ordering.
        echo 'AT_M4DIR="m4"' >> "$portage/env/kbd.conf"
        echo 'sys-apps/kbd kbd.conf' >> "$portage/package.env/kbd.conf"

        # Avoid some Python nonsense.
        echo 'sys-apps/portage -rsync-verify' >> "$portage/package.use/portage.conf"

        # Disable multilib to prevent BDEPEND from breaking everything.
        $cat << 'EOF' >> "$portage/profile/use.mask"
# Disable multilib for RISC-V.
abi_riscv_lp64
abi_riscv_lp64d
EOF

        # The multilib subdirectories in RISC-V don't work without split-usr.
        $sed -i -e 's/^multilib_layout/&() { : ; } ; x/' "$buildroot/var/db/repos/gentoo/sys-apps/baselayout/baselayout-2.7.ebuild"
        enter /usr/bin/ebuild /var/db/repos/gentoo/sys-apps/baselayout/baselayout-2.7.ebuild manifest

        # Enable general system settings.
        echo >> "$portage/make.conf" 'USE="$USE' \
            curl dbus elfutils gcrypt gdbm git gmp gnutls gpg libnotify libxml2 mpfr nettle ncurses pcre2 readline sqlite udev uuid xml \
            bidi fribidi harfbuzz icu idn libidn2 nls truetype unicode \
            apng gif imagemagick jbig jpeg jpeg2k png svg webp xpm \
            alsa flac libsamplerate mp3 ogg pulseaudio sndfile sound speex vorbis \
            a52 aom dvd libaom mpeg theora vpx x265 \
            bzip2 gzip lz4 lzma lzo xz zlib zstd \
            acl caps cracklib fprint hardened pam seccomp smartcard xattr xcsecurity \
            acpi dri gallium kms libglvnd libkms opengl usb uvm vaapi vdpau wps \
            cairo gtk3 libdrm pango plymouth X xa xcb xft xinerama xkb xorg xrandr xvmc \
            branding ipv6 jit lto offensive threads \
            dynamic-loading hwaccel postproc startup-notification toolkit-scroll-bars user-session wide-int \
            -cups -debug -emacs -fortran -gallium -geolocation -gtk -gtk2 -introspection -llvm -oss -perl -python -sendmail -tcpd -vala -X'"'

        # Build less useless stuff on the host from bad dependencies.
        echo >> "$buildroot/etc/portage/make.conf" 'USE="$USE' \
            -cups -debug -emacs -fortran -gallium -geolocation -gtk -gtk2 -introspection -llvm -oss -perl -python -sendmail -tcpd -vala -X'"'

        # Install Emacs as a terminal application.
        fix_package emacs
        packages+=(app-editors/emacs)

        # Configure the kernel by only enabling this system's settings.
        write_minimal_system_kernel_configuration > "$output/config"
        enter /usr/bin/make -C /usr/src/linux allnoconfig ARCH=riscv \
            CROSS_COMPILE="${options[host]}-" KCONFIG_ALLCONFIG=/wd/config V=1
}

function customize() {
        drop_debugging
        drop_development
        store_home_on_var +root

        echo riscv > root/etc/hostname

        # Drop extra unused paths.
        exclude_paths+=(
                usr/lib/firmware
                usr/local
        )

        # Dump emacs into the image since QEMU is built already anyway.
        local -r host=${options[host]}
        local -r gccdir=/$(cd "/usr/$host" ; compgen -G "usr/lib/gcc/$host/*")
        ln -ft "/usr/$host/tmp" /usr/bin/qemu-riscv64
        chroot "/usr/$host" \
            /tmp/qemu-riscv64 -cpu rv64 -E "LD_LIBRARY_PATH=$gccdir" \
            /usr/bin/emacs --batch --eval='(dump-emacs-portable "/tmp/emacs.pdmp")'
        rm -f root/usr/libexec/emacs/*/*/emacs.pdmp \
            root/usr/lib/systemd/system{,/multi-user.target.wants}/emacs-pdmp.service
        cp -pt root/usr/libexec/emacs/*/"$host" "/usr/$host/tmp/emacs.pdmp"

        # Build U-Boot to provide UEFI.
        git clone --branch=v2020.07-rc3 --depth=1 https://github.com/u-boot/u-boot.git /root/u-boot
        git -C /root/u-boot reset --hard 8c48bb21bd6a1778d1f299de30ff62c07929702b
        cat /root/u-boot/configs/qemu-riscv64_smode_defconfig - << 'EOF' > /root/u-boot/.config
CONFIG_BOOTCOMMAND="fatload virtio 0:1 ${kernel_addr_r} /EFI/BOOT/BOOTRISCV64.EFI;bootefi ${kernel_addr_r}"
CONFIG_BOOTDELAY=0
EOF
        make -C /root/u-boot -j"$(nproc)" olddefconfig CROSS_COMPILE="${options[host]}-" V=1
        make -C /root/u-boot -j"$(nproc)" all CROSS_COMPILE="${options[host]}-" V=1

        # Build OpenSBI with a U-Boot payload for the firmware image.
        git clone --branch=v0.7 --depth=1 https://github.com/riscv/opensbi.git /root/opensbi
        git -C /root/opensbi reset --hard 9f1b72ce66d659e91013b358939e832fb27223f5
        make -C /root/opensbi -j"$(nproc)" all \
            CROSS_COMPILE="${options[host]}-" FW_PAYLOAD_PATH=/root/u-boot/u-boot.bin PLATFORM=qemu/virt V=1
        cp -p /root/opensbi/build/platform/qemu/virt/firmware/fw_payload.bin opensbi-uboot.bin
        chmod 0644 opensbi-uboot.bin

        # Support an executable VM image for quick testing.
        cp -pt . /usr/bin/qemu-system-riscv64
        cat << 'EOF' > launch.sh && chmod 0755 launch.sh
#!/bin/bash -eu
exec qemu-system-riscv64 -nographic \
    -L "$PWD" -bios opensbi-uboot.bin \
    -machine virt -cpu rv64 -m 4G \
    -drive file="${IMAGE:-disk.exe}",format=raw,id=hd0,media=disk \
    -netdev user,id=net0 \
    -object rng-random,id=rng0 \
    -device virtio-blk-device,drive=hd0 \
    -device virtio-net-device,netdev=net0 \
    -device virtio-rng-device,rng=rng0 \
    "$@"
EOF
}

# Override the UEFI function as a hack to produce a UEFI GRUB image for the
# bootloader until the systemd boot stub exists for RISC-V.
function produce_uefi_exe() if opt uefi
then
        grub-mkimage \
            --compression=none \
            --format=riscv64-efi \
            --output=BOOTRISCV64.EFI \
            --prefix='(hd0,gpt1)/' \
            fat halt linux loadenv minicmd normal part_gpt reboot test
        cat << EOF > grub.cfg
set default=boot-a
set timeout=3
menuentry 'Boot A' --id boot-a {
        linux /linux_a console=ttyS0 earlycon=sbi $(<kernel_args.txt)
        if test -s /initrd_a ; then initrd /initrd_a ; fi
}
menuentry 'U-Boot' --id uboot {
        exit
}
menuentry 'Reboot' --id reboot {
        reboot
}
menuentry 'Power Off' --id poweroff {
        halt
}
EOF
fi

# Override zstd initrd compression since RC kernels don't have the patch.
eval "$(
declare -f build_busybox_initrd | $sed 's/zstd.*-22/xz --check=crc32 -9e/'
declare -f write_base_kernel_config | $sed s/RD_ZSTD/RD_XZ/
)"

# Override executable image generation to force GRUB into the mix.
eval "$(declare -f produce_executable_image | $sed '
/^ *opt uefi/{s/BOOT[0-9A-Z]*.EFI/vmlinuz/;s/) + /) * 2 + /;}
s,mcopy.*X64.EFI.*,&\nmcopy -i esp.img vmlinuz ::/linux_a\ntest -s initrd.img \&\& mcopy -i esp.img initrd.img ::/initrd_a\nmcopy -i esp.img grub.cfg ::/grub.cfg,
s/BOOTX64/BOOTRISCV64/g')"

function write_minimal_system_kernel_configuration() { $cat "$output/config.base" - << 'EOF' ; }
# XXX: Stuff apparently needed by the experimental UEFI patches to compile 5.7.
CONFIG_RISCV_SBI_V01=y
CONFIG_VT=y
CONFIG_DUMMY_CONSOLE=y
# Show initialization messages.
CONFIG_PRINTK=y
## Output early printk messages to the console.
CONFIG_HVC_RISCV_SBI=y
CONFIG_SERIAL_EARLYCON_RISCV_SBI=y
# Support ext2/ext3/ext4 (which is not included for read-only images).
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_EXT4_USE_FOR_EXT2=y
# Support encrypted partitions.
CONFIG_DM_CRYPT=m
CONFIG_DM_INTEGRITY=m
# Support FUSE.
CONFIG_FUSE_FS=m
# Support running containers in nspawn.
CONFIG_POSIX_MQUEUE=y
CONFIG_SYSVIPC=y
CONFIG_IPC_NS=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_USER_NS=y
CONFIG_UTS_NS=y
# Support mounting disk images.
CONFIG_BLK_DEV=y
CONFIG_BLK_DEV_LOOP=y
# Build basic firewall filter options.
CONFIG_NETFILTER=y
CONFIG_NF_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_STATE=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP6_NF_FILTER=y
# Support some optional systemd functionality.
CONFIG_COREDUMP=y
CONFIG_MAGIC_SYSRQ=y
CONFIG_NET_SCHED=y
CONFIG_NET_SCH_DEFAULT=y
CONFIG_NET_SCH_FQ_CODEL=y
# TARGET HARDWARE: QEMU (virtio)
CONFIG_FPU=y
CONFIG_SOC_VIRT=y
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO_MMIO=y
## QEMU virtio network
CONFIG_NETDEVICES=y
CONFIG_NET_CORE=y
CONFIG_VIRTIO_NET=y
## QEMU virtio disk
CONFIG_VIRTIO_BLK=y
## QEMU virtio console
CONFIG_TTY=y
CONFIG_VIRTIO_CONSOLE=y
## QEMU virtio RNG
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_VIRTIO=y
## QEMU default serial port
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
EOF
