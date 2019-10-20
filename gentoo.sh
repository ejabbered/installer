packages=()
packages_buildroot=()

DEFAULT_PROFILE=17.1
DEFAULT_RELEASE=$($curl -L https://gentoo.osuosl.org/releases/amd64/autobuilds/latest-stage3-amd64-hardened-selinux+nomultilib.txt | $sed -n '/^[0-9]\{8\}T[0-9]\{6\}Z/{s/Z.*/Z/p;q;}')
options[arch]=$DEFAULT_ARCH
options[profile]=$DEFAULT_PROFILE
options[release]=$DEFAULT_RELEASE

function create_buildroot() {
        local -A archmap=([x86_64]=amd64)
        local -r arch="${archmap[$DEFAULT_ARCH]:-amd64}"
        local profile="default/linux/$arch/${options[profile]:=$DEFAULT_PROFILE}/no-multilib/hardened"
        local stage3="https://gentoo.osuosl.org/releases/$arch/autobuilds/${options[release]:=$DEFAULT_RELEASE}/hardened/stage3-$arch-hardened+nomultilib-${options[release]}.tar.xz"

        opt bootable || opt selinux && packages_buildroot+=(sys-kernel/gentoo-sources)
        opt executable && opt uefi && packages_buildroot+=(sys-fs/dosfstools)
        opt ramdisk || opt selinux && packages_buildroot+=(app-arch/cpio sys-apps/busybox)
        opt selinux && packages_buildroot+=(app-emulation/qemu) && profile+=/selinux && stage3=${stage3/+/-selinux+}
        opt squash && packages_buildroot+=(sys-fs/squashfs-tools)
        opt verity && packages_buildroot+=(sys-fs/cryptsetup)
        opt uefi && packages_buildroot+=(media-gfx/imagemagick x11-themes/gentoo-artwork) &&
        opt sb_cert && opt sb_key && packages_buildroot+=(app-crypt/pesign dev-libs/nss)
        packages_buildroot+=(dev-util/debugedit sys-devel/crossdev)

        $mkdir -p "$buildroot"
        $curl -L "$stage3.DIGESTS.asc" > "$output/digests"
        $curl -L "$stage3" > "$output/stage3.tar.xz"
        verify_distro "$output/digests" "$output/stage3.tar.xz"
        $tar -C "$buildroot" -xJf "$output/stage3.tar.xz"
        $rm -f "$output/digests" "$output/stage3.tar.xz"

        script << EOF
ln -fns /var/db/repos/gentoo/profiles/$profile /etc/portage/make.profile
mkdir -p /etc/portage/{env,package.{accept_keywords,env,license,unmask,use},profile,repos.conf}
cat <(echo) - << 'EOG' >> /etc/portage/make.conf
FEATURES="\$FEATURES multilib-strict parallel-fetch parallel-install xattr -selinux"
POLICY_TYPES="targeted"
USE="\$USE ${options[selinux]:+selinux} systemd"
EOG
echo -e '-selinux\n-static\n-static-libs' >> /etc/portage/profile/use.force
echo -e 'sslv2\nsslv3\n-cet\n-systemd' >> /etc/portage/profile/use.mask
cat << 'EOG' >> /etc/portage/profile/package.provided
# These Python tools are not useful, and they pull in horrific dependencies.
app-admin/setools-9999
EOG

# Accept the newest kernel and SELinux policy.
echo sys-kernel/gentoo-sources >> /etc/portage/package.accept_keywords/linux.conf
echo sys-kernel/linux-headers >> /etc/portage/package.accept_keywords/linux.conf
echo 'sec-policy/*' >> /etc/portage/package.accept_keywords/selinux.conf

# Accept the Secure Boot signing utility.
echo app-crypt/pesign >> /etc/portage/package.accept_keywords/pesign.conf

# Accept CPU microcode licenses.
echo sys-firmware/intel-microcode intel-ucode >> /etc/portage/package.license/ucode.conf
echo sys-kernel/linux-firmware linux-fw-redistributable no-source-code >> /etc/portage/package.license/ucode.conf

# Support SELinux with systemd.
echo -e 'sys-apps/gentoo-systemd-integration\nsys-apps/systemd' >> /etc/portage/package.unmask/systemd.conf

# Support zstd squashfs compression (and fix a missing linked library).
echo '~sys-fs/squashfs-tools-4.4' >> /etc/portage/package.accept_keywords/squashfs-tools.conf
echo 'sys-fs/squashfs-tools zstd' >> /etc/portage/package.use/squashfs-tools.conf
echo 'LDFLAGS="-lgcc_s \$LDFLAGS"' >> /etc/portage/env/squashfs-tools.conf
echo 'sys-fs/squashfs-tools squashfs-tools.conf' >> /etc/portage/package.env/squashfs-tools.conf

# Fix bad packaging not being compatible with UsrMerge.
echo 'PKG_INSTALL_MASK="/lib*/libpam*.so"' >> /etc/portage/env/pam.conf
echo 'PKG_INSTALL_MASK="/usr/sbin/setfiles"' >> /etc/portage/env/policycoreutils.conf
echo 'sys-libs/pam pam.conf' >> /etc/portage/package.env/pam.conf
echo 'sys-apps/policycoreutils policycoreutils.conf' >> /etc/portage/package.env/policycoreutils.conf

# Fix cross-compiling GPG.
echo 'CPPFLAGS="-I\${SYSROOT}/usr/include/libusb-1.0"' > /etc/portage/env/gnupg.conf
echo 'app-crypt/gnupg gnupg.conf' > /etc/portage/package.env/gnupg.conf

# Turn off extra busybox features to make initrds smaller.
echo 'sys-apps/busybox -* static' >> /etc/portage/package.use/host.conf

# Statically link dmsetup to only need to copy one file into the initrd.
${options[ramdisk]:+:} false && cat << 'EOG' >> /etc/portage/package.use/host.conf
dev-libs/libaio static-libs
sys-apps/util-linux static-libs
sys-fs/lvm2 -* device-mapper-only static
EOG

# Support building the UEFI boot stub, its logo image, and signing tools.
${options[uefi]:+:} false && cat << 'EOG' >> /etc/portage/package.use/host.conf
dev-libs/nss utils
media-gfx/imagemagick png
sys-apps/systemd gnuefi
sys-apps/pciutils -udev
EOG

emerge-webrsync
emerge --changed-use --deep --jobs=4 --update --verbose --with-bdeps=y \
    @world ${packages_buildroot[*]} $*

test -d /usr/src/linux && make -C /usr/src/linux -j$(nproc) mrproper V=1

cat << 'EOG' >> /etc/portage/repos.conf/crossdev.conf
[crossdev]
location = /var/db/repos/crossdev
EOG

mkdir -p "/usr/${options[arch]}-gentoo-linux-gnu/etc"
cp -at "/usr/${options[arch]}-gentoo-linux-gnu/etc" /etc/portage
cd "/usr/${options[arch]}-gentoo-linux-gnu/etc/portage"
cat << 'EOG' >> make.conf
CHOST="${options[arch]}-gentoo-linux-gnu"
ROOT="/usr/\$CHOST"
SYSROOT="\$ROOT"
PKG_CONFIG_SYSROOT_DIR="\$SYSROOT"
PKGDIR="\$ROOT/var/cache/binpkgs"
PYTHON_TARGETS="\$PYTHON_SINGLE_TARGET"
FEATURES="\$FEATURES buildpkg compressdebug installsources pkgdir-index-trusted splitdebug"
USE="\$USE -static -static-libs"
EOG
cat << 'EOG' >> package.use/kill.conf
# Use the kill command from util-linux to minimize systemd dependencies.
sys-apps/coreutils -kill
sys-apps/util-linux kill
sys-process/procps -kill
EOG
rm -f package.use/host.conf
echo split-usr >> profile/use.mask
EOF

        build_relabel_kernel
        write_base_kernel_config
}

function install_packages() {
        opt bootable || opt networkd && packages+=(sys-apps/systemd)
        opt selinux && packages+=(sec-policy/selinux-base-policy)
        packages+=(sys-apps/baselayout)

        # Create the cross-compiler toolchain in the native build root.
        crossdev --stable --target "${options[arch]}-gentoo-linux-gnu"

        # Initialize a directory layout for the cross-compiled build root.
        local -rx {PORTAGE_CONFIG,,SYS}ROOT="/usr/${options[arch]}-gentoo-linux-gnu"
        mkdir -p "$ROOT"/{lib,lib64,usr/{lib,lib64,src}}

        # Build the final kernel, and link its configuration in the build root.
        if opt bootable
        then
                test -s /usr/src/linux/.config
                make -C /usr/src/linux -j$(nproc) V=1
                make -C /usr/src/linux install V=1
                ln -fst "$ROOT/usr/src" ../../../../usr/src/linux
        fi

        # Build the cross-compiled toolchain packages first.
        USE=-selinux emerge --jobs=4 --verbose \
            sys-devel/gcc sys-kernel/linux-headers sys-libs/glibc
        packages+=(sys-devel/gcc sys-libs/glibc)  # Install libstdc++ etc.

        # Install these outside the dependency graph because portage is broken.
        emerge --jobs=4 --nodeps --verbose \
            ${options[selinux]:+sec-policy/selinux-base} x11-base/xcb-proto

        # Cheat systemd bootstrapping.
        USE='-* kill' emerge --jobs=4 --verbose sys-apps/util-linux

        # Cross-compile everything and make binary packages for the target.
        emerge --changed-use --deep --jobs=4 --update --verbose --with-bdeps=y \
            @world "${packages[@]}" "$@"

        # Install the target root from binaries with no build dependencies.
        mkdir -p root/{dev,etc,home,proc,run,srv,sys,usr/{bin,lib,sbin}}
        mkdir -pm 0700 root/root
        [[ ${options[arch]-} =~ 64 ]] && ln -fns lib root/usr/lib64
        (cd root ; exec ln -fst . usr/*)
        ln -fns .. "root/usr/${options[arch]}-gentoo-linux-gnu"  # Lazily work around bad packaging.
        emerge --{,sys}root=root --jobs=$(nproc) -1Kv "${packages[@]}" "$@"
        rm -f "root/usr/${options[arch]}-gentoo-linux-gnu"

        qlist -CIRSSUv > packages-buildroot.txt
        qlist --root=/ -CIRSSUv > packages-host.txt
        qlist --root=root -CIRSSUv > packages.txt
}

function distro_tweaks() {
        ln -fns ../lib/systemd/systemd root/usr/sbin/init
        ln -fns ../proc/self/mounts root/etc/mtab

        sed -i -e '/^SELINUXTYPE=/s/=.*/=targeted/' root/etc/selinux/config

        sed -i -e 's/PS1+=..[[]/&\\033[01;33m\\]$? \\[/;/\$ .$/s/PS1+=./&$? /' root/etc/bash/bashrc
        echo "alias ll='ls -l'" >> root/etc/skel/.bashrc

        # The targeted policy does not support a sensitivity level.
        sed -i -e 's/t:s0/t/g' \
            root/usr/lib/systemd/system{/*.mount,-generators/etcgo*}

        # Magenta looks more "Gentoo" than green, as in the website and logo.
        sed -i -e '/^ANSI_COLOR=/s/32/35/' root/etc/os-release
}

function save_boot_files() if opt bootable
then
        test -s vmlinuz || cp -p /boot/vmlinuz-* vmlinuz
        opt uefi && test ! -s logo.bmp && convert -background none /usr/share/pixmaps/gentoo/1280x1024/LarryCowBlack1280x1024.png -crop 380x324+900+700 -trim -transparent black -color-matrix '0 1 0 0 0 0 1 0 0 0 0 1 1 0 0 0' logo.bmp
        test -s os-release || cp -pt . root/etc/os-release
fi

function build_ramdisk() if opt ramdisk
then
        local -r root=$(mktemp --directory --tmpdir="$PWD" ramdisk.XXXXXXXXXX)
        mkdir -p "$root"/{bin,dev,proc,sys,sysroot}
        cp -pt "$root/bin" /bin/busybox
        for cmd in ash mount losetup switch_root
        do ln -fns busybox "$root/bin/$cmd"
        done
        opt verity && cp -p /sbin/dmsetup.static "$root/bin/dmsetup"
        cat << EOF > "$root/init" && chmod 0755 "$root/init"
#!/bin/ash -eux
export PATH=/bin
mount -nt devtmpfs devtmpfs /dev
mount -nt proc proc /proc
mount -nt sysfs sysfs /sys
losetup $(opt read_only && echo -r) /dev/loop0 /sysroot/root.img
$(opt verity && cat << EOG ||
dmsetup create --concise '$(<dmsetup.txt)'
mount -no ro /dev/mapper/root /sysroot
EOG
echo "mount -n$(opt read_only && echo o ro) /dev/loop0 /sysroot")
exec switch_root /sysroot /sbin/init
EOF
        ln -fn final.img "$root/sysroot/root.img"
        find "$root" -mindepth 1 -printf '%P\n' |
        cpio -D "$root" -H newc -R 0:0 -o |
        xz --check=crc32 -9e > ramdisk.img
fi

function write_base_kernel_config() if opt bootable
then
        echo '# Basic settings
CONFIG_ACPI=y
CONFIG_BLOCK=y
CONFIG_MULTIUSER=y
CONFIG_SHMEM=y
CONFIG_UNIX=y
# File system settings
CONFIG_DEVTMPFS=y
CONFIG_OVERLAY_FS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
# Executable settings
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
# Security settings
CONFIG_FORTIFY_SOURCE=y
CONFIG_RETPOLINE=y'
        test "x${options[arch]}" = xx86_64 && echo '# Architecture settings
CONFIG_64BIT=y
CONFIG_SMP=y
CONFIG_X86_LOCAL_APIC=y'
        opt networkd && echo '# Network settings
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_PACKET=y'
        opt ramdisk && echo '# Initrd settings
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_XZ=y
# Loop settings
CONFIG_BLK_DEV=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_LOOP_MIN_COUNT=1'
        opt selinux && echo '# SELinux settings
CONFIG_AUDIT=y
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_SELINUX=y'
        opt squash && echo '# Squashfs settings
CONFIG_MISC_FILESYSTEMS=y
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_FILE_DIRECT=y
CONFIG_SQUASHFS_DECOMP_MULTI=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_ZSTD=y' || echo '# Ext[2-4] settings
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_EXT4_USE_FOR_EXT2=y'
        opt uefi && echo '# UEFI settings
CONFIG_EFI=y
CONFIG_EFI_STUB=y'
        opt verity && echo '# Verity settings
CONFIG_MD=y
CONFIG_BLK_DEV_DM=y
CONFIG_DM_INIT=y
CONFIG_DM_VERITY=y
CONFIG_CRYPTO_SHA256=y'
        echo '# Settings for systemd as decided by Gentoo, plus some missing
CONFIG_DMI=y
CONFIG_NAMESPACES=y
CONFIG_GENTOO_LINUX=y
CONFIG_GENTOO_LINUX_UDEV=y
CONFIG_GENTOO_LINUX_INIT_SYSTEMD=y
CONFIG_FILE_LOCKING=y
CONFIG_FUTEX=y
CONFIG_POSIX_TIMERS=y
CONFIG_PROC_SYSCTL=y
CONFIG_UNIX98_PTYS=y'
else $rm -f "$output/config.base"
fi > "$output/config.base"

function build_relabel_kernel() if opt selinux
then
        echo > "$output/config.relabel" '# Assume x86_64 for now.
CONFIG_64BIT=y
CONFIG_SMP=y
# Support executing programs and scripts.
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
# Support kernel file systems.
CONFIG_DEVTMPFS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
# Support labeling the root file system.
CONFIG_BLOCK=y
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_SECURITY=y
# Support using an initrd.
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_XZ=y
# Support SELinux.
CONFIG_NET=y
CONFIG_AUDIT=y
CONFIG_MULTIUSER=y
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_INET=y
CONFIG_SECURITY_SELINUX=y
# Support initial SELinux labeling.
CONFIG_FUTEX=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
# Support POSIX timers for mksquashfs.
CONFIG_POSIX_TIMERS=y
# Support the default hard drive in QEMU.
CONFIG_PCI=y
CONFIG_ATA=y
CONFIG_ATA_BMDMA=y
CONFIG_ATA_SFF=y
CONFIG_BLK_DEV_SD=y
CONFIG_ATA_PIIX=y
# Support a console on the default serial port in QEMU.
CONFIG_TTY=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
# Support powering off QEMU.
CONFIG_ACPI=y
# Print initialization messages for debugging.
CONFIG_PRINTK=y'

        script << 'EOF'
make -C /usr/src/linux -j$(nproc) allnoconfig KCONFIG_ALLCONFIG="$PWD/config.relabel" V=1
make -C /usr/src/linux -j$(nproc) V=1
make -C /usr/src/linux install V=1
mv /boot/vmlinuz-* vmlinuz.relabel
rm -f /boot/*
exec make -C /usr/src/linux -j$(nproc) mrproper V=1
EOF
fi

function verify_distro() {
        local -rx GNUPGHOME="$output/gnupg"
        trap -- "$rm -fr $GNUPGHOME" RETURN
        $mkdir -pm 0700 "$GNUPGHOME"
        $gpg --import << 'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBEqUWzgBEACXftaG+HVuSQBEqdpBIg2SOVgWW/KbCihO5wPOsdbM93e+psmb
wvw+OtNHADQvxocKMuZX8Q/j5i3nQ/ikQFW5Oj6UXvl1qyxZhR2P7GZSNQxn0eMI
zAX08o691ws2/dFGXKmNT6btYJ0FxuTtTVSK6zi68WF+ILGK/O2TZXK9EKfZKPDH
KHcGrUq4c03vcGANz/8ksJj2ZYEGxMr1h7Wfe9PVcm0gCB1MhYHNR755M47V5Pch
fyxbs6vaKz82PgrNjjjbT0PISvnKReUOdA2PFUWry6UKQkiVrLVDRkd8fryLL8ey
5JxgVoJZ4echoVWQ0JYJ5lJTWmcZyxQYSAbz2w9dLB+dPyyGpyPp1KX1ADukbROp
9S11I9+oVnyGdUBm+AUme0ecekWvt4qiCw3azghLSwEyGZc4a8nNcwSqFmH7Rqdd
1+gHc+4tu4WHmguhMviifGXKyWiRERULp0obV33JEo/c4uwyAZHBTJtKtVaLb92z
aRdh1yox2I85iumyt62lq9dfOuet4NNVDnUkqMYCQD23JB8IM+qnVaDwJ6oCSIKi
nY3uyoqbVE6Lkm+Hk5q5pbvg1cpEH6HWWAl20EMCzMOoMcH0tPyQLDlD2Mml7veG
kwdy3S6RkjCympbNzqWec2+hkU2c93Bgpfh7QP0GDN0qrzcNNFmrD5795QARAQAB
tFNHZW50b28gTGludXggUmVsZWFzZSBFbmdpbmVlcmluZyAoQXV0b21hdGVkIFdl
ZWtseSBSZWxlYXNlIEtleSkgPHJlbGVuZ0BnZW50b28ub3JnPokCUgQTAQoAPAYL
CQgHAwIEFQIIAwMWAgECHgECF4ACGwMWIQQT672+3noSd139sbq7Vy4OLRgpEAUC
XMRr7wUJFGgDagAKCRC7Vy4OLRgpEMG6D/9ppsqaA6C8VXADtKnHYH77fb9SAsAY
YcDpZnT8wcfMlOTA7c5rEjNXuWW0BFNBi13CCPuThNbyLWiRhmlVfb6Mqp+J+aJc
rSHTQrBtByFDmXKnaljOrVKVej7uL+sdRen/tGhd3OZ5nw38fNID8nv7ZQiSlCQh
luKnfMDw/ukvPuzaTmVHEJ6udI0PvRznk3XgSb6ZSi2BZYHn1/aoDkKN9OswiroJ
pPpDAib9bzitb9FYMOWhra9Uet9akWnVxnM+XIK2bNkO2dbeClJMszN93r0BIvSu
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
yqu4wb67pwMX312ABdpW
=kSzn
-----END PGP PUBLIC KEY BLOCK-----
EOF
        $gpg --verify "$1"
        test x$($sed -n '/^[0-9a-f]/{s/ .*//p;q;}' "$1") = x$($sha512sum "$2" | $sed -n '1s/ .*//p')
}
