packages=(glibc-minimal-langpack)
packages_buildroot=(glibc-minimal-langpack)

options[verity_sig]=

DEFAULT_RELEASE=32

function create_buildroot() {
        local -r cver=$(test "x${options[release]-}" = x31 && echo 1.9 || echo 1.6)
        local -r image="https://dl.fedoraproject.org/pub/fedora/linux/releases/${options[release]:=$DEFAULT_RELEASE}/Container/$DEFAULT_ARCH/images/Fedora-Container-Base-${options[release]}-$cver.$DEFAULT_ARCH.tar.xz"

        opt bootable && packages_buildroot+=(kernel-core microcode_ctl)
        opt bootable && opt squash && packages_buildroot+=(kernel-modules)
        opt executable && opt uefi && packages_buildroot+=(dosfstools mtools)
        opt read_only && ! opt squash && packages_buildroot+=(erofs-utils)
        opt secureboot && packages_buildroot+=(nss-tools pesign)
        opt selinux && packages_buildroot+=(busybox kernel-core policycoreutils qemu-system-x86-core)
        opt squash && packages_buildroot+=(squashfs-tools)
        opt verity && packages_buildroot+=(veritysetup)
        opt uefi && packages_buildroot+=(binutils fedora-logos ImageMagick)
        packages_buildroot+=(e2fsprogs)

        $mkdir -p "$buildroot"
        $curl -L "${image%-Base*}-${options[release]}-$cver-$DEFAULT_ARCH-CHECKSUM" > "$output/checksum"
        $curl -L "$image" > "$output/image.tar.xz"
        verify_distro "$output/checksum" "$output/image.tar.xz"
        $tar -xJOf "$output/image.tar.xz" '*/layer.tar' | $tar -C "$buildroot" -x
        $rm -f "$output/checksum" "$output/image.tar.xz"

        # Disable bad packaging options.
        $sed -i -e '/^[[]main]/ainstall_weak_deps=False' "$buildroot/etc/dnf/dnf.conf"
        $sed -i -e 's/^enabled=1.*/enabled=0/' "$buildroot"/etc/yum.repos.d/*modular*.repo

        configure_initrd_generation
        initialize_buildroot

        enter /usr/bin/dnf --assumeyes upgrade
        enter /usr/bin/dnf --assumeyes install "${packages_buildroot[@]}" "$@"

        # Let the configuration decide if the system should have documentation.
        $sed -i -e '/^tsflags=/d' "$buildroot/etc/dnf/dnf.conf"
}

function install_packages() {
        opt bootable || opt networkd && packages+=(systemd)
        opt selinux && packages+=(selinux-policy-targeted)

        mkdir -p root/var/cache/dnf
        mount --bind /var/cache/dnf root/var/cache/dnf
        trap -- 'umount root/var/cache/dnf ; trap - RETURN' RETURN

        dnf --assumeyes --installroot="$PWD/root" \
            ${options[arch]:+--forcearch="${options[arch]}"} \
            --releasever="${options[release]}" \
            install "${packages[@]:-filesystem}" "$@"

        rpm -qa | sort > packages-buildroot.txt
        rpm --root="$PWD/root" -qa | sort > packages.txt
}

function distro_tweaks() {
        exclude_paths+=('usr/lib/.build-id')

        rm -fr root/etc/inittab root/etc/rc.d

        test -x root/usr/bin/update-crypto-policies &&
        chroot root /usr/bin/update-crypto-policies --set FUTURE

        test -s root/etc/dnf/dnf.conf &&
        sed -i -e '/^[[]main]/ainstall_weak_deps=False' root/etc/dnf/dnf.conf

        compgen -G 'root/etc/yum.repos.d/*modular*.repo' &&
        sed -i -e 's/^enabled=1.*/enabled=0/' root/etc/yum.repos.d/*modular*.repo

        sed -i -e 's/^[^#]*PS1="./&\\$? /;s/mask 002$/mask 022/' root/etc/bashrc
}

function save_boot_files() if opt bootable
then
        opt uefi && test ! -s logo.bmp &&
        sed -i -e '/id="g524[17]"/,/\//{/</,/>/d;}' /usr/share/fedora-logos/fedora_logo.svg &&
        convert -background none /usr/share/fedora-logos/fedora_logo.svg -trim -color-matrix '0 1 0 0 0 0 1 0 0 0 0 1 1 0 0 0' logo.bmp
        test -s initrd.img || cp -p /boot/initramfs-* initrd.img
        build_systemd_ramdisk
        test -s vmlinuz || cp -pt . /lib/modules/*/vmlinuz
fi

function configure_initrd_generation() if opt bootable
then
        # Don't expect that the build system is the target system.
        $mkdir -p "$buildroot/etc/dracut.conf.d"
        echo 'hostonly="no"' > "$buildroot/etc/dracut.conf.d/99-settings.conf"

        # The initrd build script won't run without an ID since Fedora 31.
        if ! test -s "$buildroot/etc/machine-id"
        then
                local -r container_id=$(</proc/sys/kernel/random/uuid)
                echo "${container_id//-}" > "$buildroot/etc/machine-id"
        fi

        # Load NVMe support before verity so dm-init can find the partition.
        if opt nvme
        then
                $mkdir -p "$buildroot/usr/lib/modprobe.d"
                echo > "$buildroot/usr/lib/modprobe.d/nvme-verity.conf" \
                    'softdep dm-verity pre: nvme'
        fi

        # Since systemd can't skip canonicalization, wait for a udev hack.
        if opt verity
        then
                local dropin=/usr/lib/systemd/system/sysroot.mount.d
                $mkdir -p "$buildroot$dropin"
                echo > "$buildroot$dropin/verity-root.conf" '[Unit]
After=dev-mapper-root.device
Requires=dev-mapper-root.device'
                echo >> "$buildroot/etc/dracut.conf.d/99-settings.conf" \
                    "install_optional_items+=\" $dropin/verity-root.conf \""
        fi

        # Create a generator to handle verity ramdisks since dm-init can't.
        opt verity && if opt ramdisk
        then
                local -r gendir=/usr/lib/systemd/system-generators
                $mkdir -p "$buildroot$gendir"
                echo > "$buildroot$gendir/dmsetup-verity-root" '#!/bin/bash -eu
read -rs cmdline < /proc/cmdline
test "x${cmdline}" != "x${cmdline%%DVR=\"*\"*}" || exit 0
concise=${cmdline##*DVR=\"} concise=${concise%%\"*}
device=${concise#* * * * } device=${device%% *}
if [[ $device =~ ^[A-Z]+= ]]
then
        tag=${device%%=*} tag=${tag,,}
        device=${device#*=}
        [ $tag = partuuid ] && device=${device,,}
        device="/dev/disk/by-$tag/$device"
fi
device=$(systemd-escape --path "$device").device
rundir=/run/systemd/system
echo > "$rundir/dmsetup-verity-root.service" "[Unit]
DefaultDependencies=no
After=$device
Requires=$device
[Service]
ExecStart=/usr/sbin/dmsetup create --concise \"$concise\"
RemainAfterExit=yes
Type=oneshot"
mkdir -p "$rundir/dev-dm\x2d0.device.requires"
ln -fst "$rundir/dev-dm\x2d0.device.requires" ../dmsetup-verity-root.service'
                $chmod 0755 "$buildroot$gendir/dmsetup-verity-root"
                echo >> "$buildroot/etc/dracut.conf.d/99-settings.conf" \
                    "install_optional_items+=\" $gendir/dmsetup-verity-root \""
        else
                local dropin=/usr/lib/systemd/system/dev-dm\\x2d0.device.requires
                $mkdir -p "$buildroot$dropin"
                $ln -fst "$buildroot$dropin" ../udev-workaround.service
                echo > "$buildroot${dropin%/*}/udev-workaround.service" '[Unit]
DefaultDependencies=no
After=systemd-udev-trigger.service
[Service]
ExecStart=/usr/bin/udevadm trigger
RemainAfterExit=yes
Type=oneshot'
                echo >> "$buildroot/etc/dracut.conf.d/99-settings.conf" \
                    'install_optional_items+="' \
                    "$dropin/udev-workaround.service" \
                    "${dropin%/*}/udev-workaround.service" \
                    '"'
        fi

        # Load overlayfs in the initrd in case modules aren't installed.
        if opt read_only
        then
                $mkdir -p "$buildroot/usr/lib/modules-load.d"
                echo overlay > "$buildroot/usr/lib/modules-load.d/overlay.conf"
        fi
fi

function verify_distro() {
        local -rx GNUPGHOME="$output/gnupg"
        trap -- '$rm -fr "$GNUPGHOME" ; trap - RETURN' RETURN
        $mkdir -pm 0700 "$GNUPGHOME"

        if test "x${options[release]}" = x32
        then $gpg --import << 'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBF1RVqsBEADWMBqYv/G1r4PwyiPQCfg5fXFGXV1FCZ32qMi9gLUTv1CX7rYy
H4Inj93oic+lt1kQ0kQCkINOwQczOkm6XDkEekmMrHknJpFLwrTK4AS28bYF2RjL
M+QJ/dGXDMPYsP0tkLvoxaHr9WTRq89A+AmONcUAQIMJg3JxXAAafBi2UszUUEPI
U35MyufFt2ePd1k/6hVAO8S2VT72TxXSY7Ha4X2J0pGzbqQ6Dq3AVzogsnoIi09A
7fYutYZPVVAEGRUqavl0th8LyuZShASZ38CdAHBMvWV4bVZghd/wDV5ev3LXUE0o
itLAqNSeiDJ3grKWN6v0qdU0l3Ya60sugABd3xaE+ROe8kDCy3WmAaO51Q880ZA2
iXOTJFObqkBTP9j9+ZeQ+KNE8SBoiH1EybKtBU8HmygZvu8ZC1TKUyL5gwGUJt8v
ergy5Bw3Q7av520sNGD3cIWr4fBAVYwdBoZT8RcsnU1PP67NmOGFcwSFJ/LpiOMC
pZ1IBvjOC7KyKEZY2/63kjW73mB7OHOd18BHtGVkA3QAdVlcSule/z68VOAy6bih
E6mdxP28D4INsts8w6yr4G+3aEIN8u0qRQq66Ri5mOXTyle+ONudtfGg3U9lgicg
z6oVk17RT0jV9uL6K41sGZ1sH/6yTXQKagdAYr3w1ix2L46JgzC+/+6SSwARAQAB
tDFGZWRvcmEgKDMyKSA8ZmVkb3JhLTMyLXByaW1hcnlAZmVkb3JhcHJvamVjdC5v
cmc+iQI4BBMBAgAiBQJdUVarAhsPBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAAK
CRBsEwJtEslE0LdAD/wKdAMtfzr7O2y06/sOPnrb3D39Y2DXbB8y0iEmRdBL29Bq
5btxwmAka7JZRJVFxPsOVqZ6KARjS0/oCBmJc0jCRANFCtM4UjVHTSsxrJfuPkel
vrlNE9tcR6OCRpuj/PZgUa39iifF/FTUfDgh4Q91xiQoLqfBxOJzravQHoK9VzrM
NTOu6J6l4zeGzY/ocj6DpT+5fdUO/3HgGFNiNYPC6GVzeiA3AAVR0sCyGENuqqdg
wUxV3BIht05M5Wcdvxg1U9x5I3yjkLQw+idvX4pevTiCh9/0u+4g80cT/21Cxsdx
7+DVHaewXbF87QQIcOAing0S5QE67r2uPVxmWy/56TKUqDoyP8SNsV62lT2jutsj
LevNxUky011g5w3bc61UeaeKrrurFdRs+RwBVkXmtqm/i6g0ZTWZyWGO6gJd+HWA
qY1NYiq4+cMvNLatmA2sOoCsRNmE9q6jM/ESVgaH8hSp8GcLuzt9/r4PZZGl5CvU
eldOiD221u8rzuHmLs4dsgwJJ9pgLT0cUAsOpbMPI0JpGIPQ2SG6yK7LmO6HFOxb
Akz7IGUt0gy1MzPTyBvnB+WgD1I+IQXXsJbhP5+d+d3mOnqsd6oDM/grKBzrhoUe
oNadc9uzjqKlOrmrdIR3Bz38SSiWlde5fu6xPqJdmGZRNjXtcyJlbSPVDIloxw==
=QWRO
-----END PGP PUBLIC KEY BLOCK-----
EOF
        else $gpg --import << 'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFxq3QMBEADUhGfCfP1ijiggBuVbR/pBDSWMC3TWbfC8pt7fhZkYrilzfWUM
fTsikPymSriScONXP6DNyZ5r7tgrIVdVrJvRIqIFRO0mufp9HyfWKDO//Ctyp7OQ
zYw6NVthO/aWpyFfJpj6s4iZsYGqf9gByV8brBB8v8jEsCtVOj1BU3bMbLkMsRI9
+WiLjDYyvopqNBQuIe8ogxSxpYdbUz6+jxzfvhRoBzWdjITd//Gjd90kkrBOMWkO
LTqO133OD1WMT08G5NuQ4KhjYsVvSbBpfdkTcNuP8gBP9LxCQDc+e1eAhZ95g3qk
XLeKEK9j+F+wuG/OrEAxBsscCxXRUB38QH6CFe3UxGoSMnBi+jEhicudo+ItpFOy
7rPaYyRh4Pmu4QHcC83bNjp8NI6zTHrBmVuPqkxMn07GMAQav9ezBXj6umqTX4cU
dsJUavJrJ3u7rT0lhBdiGrQ9zPbL07u2Kn+OXPAC3dKSf7G8TvwNAdry9esGSpi3
8aa1myQYVZvAlsIBkbN3fb1wvDJE5czVhzwQ77V2t66jxeg0o9/2OZVH3CozD2Zj
v28LHuW/jnQHtsQ0fUyQYRmHxNEVkW10GGM7fQwxzpxFFS1O/2XEnfMu7yBHZsgL
SojfUct0FhLhEN/g/IINX9ZCVrzK5/De27CNjYE1cgYD/lTmQ0SyjfKVwwARAQAB
tDFGZWRvcmEgKDMxKSA8ZmVkb3JhLTMxLXByaW1hcnlAZmVkb3JhcHJvamVjdC5v
cmc+iQI+BBMBAgAoAhsPBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAUCXGrkTQUJ
Es8P/QAKCRBQyzkLPDNZxBmDD/90IFwAfFcQq5ENl7/o2CYQ9k2adTHbV5RoIOWC
/o9I5/btn1y8WDhPOUNmsgbUqRqz6srlVplg+LkpIj67PVLDBwpVbCJC8o1fztd2
MryVqdvu562WVhUorII+iW7nfqD0yv55nH9b/JR1qloUa8LpeKw84JgvxF5wVfyR
id1WjI0DBk2taFR4xCfU5Tb262fbdFj5iB9xskP7oNeS29+SfDjlnybtlFoqr9UA
nY1uvhBPkGmj45SJkpfP+L+kGYXVaUd29M/q/Pt46X1KDvr6Z0l8bSUEk3zfcNdj
uEhtHBqSy1UPPAikGX1Q5wGdu7R7+mv/ARqfI6OC44ipoOMNK1Aiu6+slbPYphwX
ighSz9yYuG0EdWt7akfKR0R04Kuej4LXLWcxTR4l8XDzThYgPP0g+z0XQJrAkVhi
SrzICeC3K1GPSiUtNAxSTL+qWWgwvQyAPNoPV/OYmY+wUxUnKCZpEWPkL79lh6CM
bJx/zlrOMzRumSzaOnKW9AOliviH4Rj89OmDifBEsQ0CewdHN9ly6g4ZFJJGYXJ5
HTb5jdButTC3tDfvH8Z7dtXKdC4iqJCIxj698Xn8UjVefZQ2nbv5eXcZLfHtvbNB
TTv1vvBV4G7aiHKYRSj7HmxhLBZC8Y/nmFAemOoOYDpR5eUmPmSbFayoLfRsFXmC
HLs7cw==
=6hRW
-----END PGP PUBLIC KEY BLOCK-----
EOF
        fi
        $gpg --verify "$1"
        test x$($sed -n '/=/{s/.* //p;q;}' "$1") = x$($sha256sum "$2" | $sed -n '1s/ .*//p')
}

# OPTIONAL (BUILDROOT)

function enable_rpmfusion() {
        local key="RPM-GPG-KEY-rpmfusion-free-fedora-${options[release]}"
        local url="https://download1.rpmfusion.org/free/fedora/releases/${options[release]}/Everything/$DEFAULT_ARCH/os/Packages/r/rpmfusion-free-release-${options[release]}-1.noarch.rpm"
        test -s "$buildroot/etc/pki/rpm-gpg/$key" || script << EOF
if test "x${options[release]}" = x32
then rpmkeys --import /dev/stdin << 'EOG'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFyps4IBEADNQys3kVRoIzE+tbfUSjneQWYYDuONJP3i9tuJjKC6NJJCDBxB
NqxRdZm2XQjF4NThJHB+wOY6/M7XRzUVPE1LtoEaA/FXj12jogt7TN5aDT4VDyRV
nBKlsW4tW/FcxPS9R7lCLsnTfX16yr59vwA6KpLR3FsbDUJyFLRX33GMxZVtVAv4
181AeBA2WdTlebR8Cb0o0QowDyWkXRP97iV+qSiwhlOmCjl5LpQY1UZZ37VhoY+Y
1TkFT8fnYKe5FO8Q5b6hFcaIESvGQ0rOAQC1GoHksG19BoQm80TzkHpFXdPmhvJT
+Q3J1xFID7WVwMtturtoTzW+MPcXcbeOquz5PbEAB3LocdYASkDcCpdLxNsVIWbe
wVyXwTM8+/3kX+Pknc4PWdauOiap9w6og6x0ki1cVbYFo6X4mtfv5leIPkhfWqGn
ZRwLNzCr/ilRuqerdkwvf0G/GebnzoSc9Sqsd552CHuXbB51OK0zP3ZnkG3y8i0R
ls3J4PZY8IHxa1T4NQ4n0h4VrZ3TJhWQMvl1eI3aeTG4yM98jm3n+TQi73Z+PxjK
+8iAa1jTjAPew1qzJxStJXy6LfNyqwtaSOYI/MWCD9F4PDvxmXhLQu/UU7F2JPJ2
4VApuAeMUDnb2aSNyCb894sJG126BwfHHjMKGAJadJInBMg9swlrx/R+AQARAQAB
tFNSUE0gRnVzaW9uIGZyZWUgcmVwb3NpdG9yeSBmb3IgRmVkb3JhICgzMikgPHJw
bWZ1c2lvbi1idWlsZHN5c0BsaXN0cy5ycG1mdXNpb24ub3JnPokCRQQTAQgALxYh
BHvamO9ZMFCjSxaXq6DunYMQC82SBQJcqbOCAhsDBAsJCAcDFQgKAh4BAheAAAoJ
EKDunYMQC82SfX0QAJJKGRFKuLX3tPHoUWutb85mXiClC1b8sLXnAGf3yZEXMZMi
yIg6HEFfjpEYGLjjZDXR7vF2NzXpdzNV9+WNt8oafpdmeFRKAl2NFED7wZXsS/Bg
KlxysH07GFEEcJ0hmeNP9fYLUZd/bpmRI/opKArKACmiJjKZGRVh7PoXJqUbeJIS
fSnSxesCQzf5BbF//tdvmjgGinowuu6e5cB3fkrJBgw1HlZmkh88IHED3Ww/49ll
dsI/e4tQZK0BydlqCWxguM/soIbfA0y/kpMb3aMRkN0pTKi7TcJcb9WWv/X96wSb
hq1LyLzh7UYDULEnC8o/Lygc8DQ9WG+NoNI7cMvXeax80qNlPS2xuCwVddXK7EBk
TgHpfG4b6/la5vH4Un3UuD03q+dq2iQn7FSFJ8iaBODg5JJQOqBLkg2dlPPv8hZK
nb3Mf7Zu0rhyBm5DSfGkSGYv8JgRGsobek+pdP7bV2RPEmEuJycz7vV6kdS1BUvW
f3wwFYe7MGXD9ITUcCq3a2TabsesqwqNzHizUbNWprrg8nQQRuEupas2+BDyGIL6
34hsfZcS8e/N7Eis+lEBEKMo7Fn36VZZXHHe7bkKPpIsxvHjNmFgvdQVAOJRR+iQ
SvzIApckQfmMKIzPJ4Mju9RmjWOQKA/PFc1RynIhemRfYCfVvCuMVSHxsqsF
=hrxJ
-----END PGP PUBLIC KEY BLOCK-----
EOG
else rpmkeys --import /dev/stdin << 'EOG'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFvEZi0BEADeq0E2/aYDWMYnUBloxAamr/DBo21/Xida69lQg/C8wGB/jz+i
J9ZDEnLRDGlotBl3lwOhbzwXxk+4azH77+JIuUDiPkBb6e7rld0EMWNykLuWifV0
Eq7qVBtr1cQfvLMDySvzIBPEGy3IbFnr7H7diR+A0WiwltVLcv4wW/ESRZUChBxy
TGgQrYk98TGiJGMWlwi7IzopOliAYrc7oM1XyZQlTffhS5b0ygiwIxGOOjVR3waB
m//0PVj8hZ+kHBgn2hXnLlWBkCRosxHmg+xcosUBgfBqKBPN8M800F6svvZS1msN
mef7y2QytA9LSpey6mznqKEY8x8+9Ub4FCGiEEw8SoDCU48NpmADr6PXoJAtihEi
4NuBiqzpabKDR7IfhEWNgVM840OCmizFyT9L++SDZmww8rUHx55VOzVEf4fSRPXY
gduexRo377+bj+wdpKfrUddkbdxuDVWweq8k5fZz7Y7HYtM60j9WxtUoLF37MNgZ
5bwrOU2NhLP+aqwyeE86/BqDdKVzxeq+PAaIl1ujTqbmJYJO0Kmt4G+GPhj6TpTq
+X+Ci+YskPEcp7dqpH38rpuA3ZAVH4tHkW9UFFBHrvnxuOLrrAflondgLTo1xNo6
E8Qrq7PGCjq/FdVM9tC3hupeKuXz5jaf65qbln4COromTXm5KyNOlWVgMwARAQAB
tFNSUE0gRnVzaW9uIGZyZWUgcmVwb3NpdG9yeSBmb3IgRmVkb3JhICgzMSkgPHJw
bWZ1c2lvbi1idWlsZHN5c0BsaXN0cy5ycG1mdXNpb24ub3JnPokCRQQTAQgALxYh
BFmn/gf2ZMGydofF0m3u8FHEgZN6BQJbxGYtAhsDBAsJCAcDFQgKAh4BAheAAAoJ
EG3u8FHEgZN6E5EQAN5kzvCyT/Ev6H/rS4QQE6+Zxb9YCGnlUOwPXcwtAqjGl4Hn
kt9LXnrd4DThLBLEGZUpBe5/oNuZOLWRWvTG7UHR+pBdtxIyqUlxBhiIwSe+Q7rZ
gehiXl2PhnaBHyTLoFGczNWiqKSIORnSmVg4SXuteG4So0PzRWBD9r2/7P/mZGyd
wyiH34YUzsedPOO1sER8o+tQ6C9RlRmhZRQ9hBJIymga1FfCms6X5lEFfbsuSjEt
acLvLJuO7bxfoYPiC2l+psFAitgT7UeEm/KW/Ul2M2YVONu1pRCkEoJzJ4B1ki9/
MK6Kw9QyQ6KXmOmzckJaInZQrwtcffjsdCjdQgoPUA//PVsysM4dtE7TPx2iRC2S
Vci0eGT+XV3tUlDDlMLfx6PhpfAddN3okGIWE0Nwc9yNwwn+R2H/Nrw0Q74qiwP7
uCgzGQBEKOATwJdm/EbtzSOzTgeunrlb1HO+XgjE+VBxp9vdzS/sOecixPyGdjW3
B1NIHAU1O9tgQcBNSJ4txKEnKHw92HViHLXpOVIIeXW+2bjtgTtTE3TfAYVnyLMn
uplg21hoH2L+fC281fgV64CzR+QjOiKWJSvub6wzy1a7/xPce8yaE89SwmxxVroS
Ia81vrdksRmtLwAhgJfh6YoSdxKWdtB+/hz2QwK+lHV368XzdeAuWQQGpX3T
=NNM4
-----END PGP PUBLIC KEY BLOCK-----
EOG
fi
curl -L "$url" > rpmfusion-free.rpm
curl -L "${url/-release-/-release-tainted-}" > rpmfusion-free-tainted.rpm
rpm --checksig rpmfusion-free{,-tainted}.rpm
rpm --install rpmfusion-free{,-tainted}.rpm
exec rm -f rpmfusion-free{,-tainted}.rpm
EOF
        test "x$*" = x+nonfree || return 0
        key=${key//free/nonfree}
        url=${url//free/nonfree}
        test -s "$buildroot/etc/pki/rpm-gpg/$key" || script << EOF
if test "x${options[release]}" = x32
then rpmkeys --import /dev/stdin << 'EOG'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFyptB8BEAC2C18FrMlCbotDF+Ki/b1sq+ACh9gl9OziTYCQveo4H/KU6PPV
9fIDlMuFLlWqIiP32m224etYafTARp3NZdeQGBwe1Cgod+HZ/Q5/lySJirsaPUMC
WQDGT9zd8BadcprbKpbS4NPg0ZDMi26OfnaJRD7ONmXZBsBJpbqsSJL/mD5v4Rfo
XmYSBzXNH2ScfRGbzVam5LPgIf7sOqPdVGUM2ZkdJ2Y2p6MHLhJko8LzVr3jhJiH
9AL0Z7f3xyepA9c8qcUx2IecZAOBIw18s9hyaXPXD4XejNP7WNAmClRhijhxBcML
TpDglKGe5zoxpXwPsavQxa7uUYVUHc83sfP04Gjj50CZpMpR9kfp/uLvzYf1KQRj
jM41900ZewXAAOScTp9vouqn23R8B8rLeQfL+HL1y47dC7dA4gvOEoAysznTed2e
fl6uu4XG9VuK1pEPolXp07nbZ1jxEm4vbWJXCuB6WDJEeRw8AsCsRPfzFk/oUWVn
kvzD0Xii6wht1fv+cmgq7ddDNuvNJ4aGi5zAmMOC9GPracWPygV+u6w/o7b8N8tI
LcHKOjOBh2orowUZJf7jF+awHjzVCFFT+fcCzDwh3df+2fLVGVL+MdTWdCif9ovT
t/SGtUK7hrOLWrDTsi1NFkvWLc8W8BGXsCTr/Qt4OHzP1Gsf17PlfsI3aQARAQAB
tFZSUE0gRnVzaW9uIG5vbmZyZWUgcmVwb3NpdG9yeSBmb3IgRmVkb3JhICgzMikg
PHJwbWZ1c2lvbi1idWlsZHN5c0BsaXN0cy5ycG1mdXNpb24ub3JnPokCRQQTAQgA
LxYhBP5ak5PLbicbWpDMGw2adpltwb4YBQJcqbQfAhsDBAsJCAcDFQgKAh4BAheA
AAoJEA2adpltwb4YBmMP/R/K7SEr6eOFLt9tmsI06BCOLwYtQw1yBPOP/QcX9vZG
Af6eWk5Otvub38ZKqxkO9j2SdAwr16cDXqL6Vfo45vqRCTaZpOBw2rRQlqgFNvQ2
7uzzUk8xkwAyh3tqcUuJjdPso/k02ZxPC5xR68pjOyyvb618RXxjuaaOHFqt2/4g
LEBGcxfuBsKMwM8uZ5r61YRyZle23Ana8edvVOQWeyzF0hx/WXCRke/nCyDEE6OA
IGhcA0XOjnzzLxTLjvmnjBUaenXnpBS8LA5OPOo0TjvPiAj7DSR8lfQYNorGxisD
cEJm/upsJii/x3Tm4dwRvlmvZuw4CC7UCQ3FIu3eAsNoqRAeV8ND33T/L3feHkxj
0fkWwihAcx12ddaRM5iOEMPNmUTyufj9KZy21jAy3AooMiDb8o17u4fb6irUs/YE
/TL1EG2W8L7R6idgjk//Ip8sNvxr3nwmyv7zJ6vWfhuS/inuEDdvHqqrs+s5n4gk
jTKf3If3e6unzMNO5945DgvXcx09G0QqgdrRLprT+bj6581YbOnzvZdUqgOaw3M5
pGdE6wHro7qtbp/HolJYx07l0AW3AW9v+mZSIBXp2UyHXzFN5ycwpgXo+rQ9mFP9
wzK/najg8b1aC99psZhS/mVVFVQJC5Ozz4j/AMIaXQPaFhAFd6uRQPu7fZX/kjmN
=U9qR
-----END PGP PUBLIC KEY BLOCK-----
EOG
else rpmkeys --import /dev/stdin << 'EOG'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFvEZjsBEADo+8aA0e20azf2vU4JJ2rVHnr9RpVUcRYmr/rFEsEeYMIvDAYz
ssprKuuz89XTe5OR8RSrTIVFOTqYrZYxuQbR35rzr9wpk45szcUMDNzi0L83AemS
v1JgBF2gSoF9Ajbhbdwxxqje+yn86u0xWWsG4Xu1N/KZE/oyqAYwWzH9nizrSRSv
SCsjZMk4SwEPB0lp2zTf21k5YwIv05+ubHq5/h9WScjjoA4LCJHIikNptONFemhS
Ys3Vsacd0g4mAx3AyU8gGaFkQXapwhQWi1/UCbqFT/3S1ZApYthdYBpFwSv7PgUa
BBJGFzwxrch9NF1wHivO4uzmPK2V8REKt2EgwPUfaAYCabPxxFFsWNOimv1zz3Wb
2DPZfE1YDjAi4qNfXENkqSReys7ETi2fGw2pr6PQtLJFYLbpKwXVvdr0PuAPPNQo
kCAuCZKnNitxsxyaGYxN2gq3D6excKpo+3JQAdRTdC+vAFACs41QDLCLBYQUL4zn
eXR/hkSmyeEDyrkuRztqUxI0eobMOS6KI6c2u+tYhWQY1OH1piV1aOa4OQQKFdZH
6WQAnbMqafG4lPmEO5cDT4JNRzWfyZXXa750mq6X3r2iRZMlroHoJAMUmF6+r8vP
AfjC3Haqfbp6HlNpTET8GU8eeeNQM33Qpq1H2tGJPIt3ZVHOTzjjMnvFdwARAQAB
tFZSUE0gRnVzaW9uIG5vbmZyZWUgcmVwb3NpdG9yeSBmb3IgRmVkb3JhICgzMSkg
PHJwbWZ1c2lvbi1idWlsZHN5c0BsaXN0cy5ycG1mdXNpb24ub3JnPokCRQQTAQgA
LxYhBEyrlRp0k9ksrewEIZzmOgNUqGCSBQJbxGY7AhsDBAsJCAcDFQgKAh4BAheA
AAoJEJzmOgNUqGCSkzwP/35oDsqFQNZGT2PJ3BpLkK/e8INCRsBgUHHzQiGri69v
OBDt6RoJwKEYfsx7ps0oRhci6NZ5aTJL4g25xBibWB9dvce4c25Kho7VHassxXzv
j6MrAuFNFHWpNNGXgiBTfMBOqcLxfx550wJyzyUVxxsmjbRm8Irz/ijZXavzyTw5
xNmZw6a2XH1Zx9bNdv+o5I5pkmdJJGSw6BbI7j5xysV+A5yIFtCnKCwhsXrGRjnR
9V8MuocAXjzayLWJ4E0daZkJlyR5mhYuae4PR1wt75qj8UesjWTAniQFlWMe52+G
Iqukb6TvxrLLTdaFi8orpoDG5PsdQ2kfyRQDcK5UMM4X8BC59Bq0NtuIezMio40O
1wGZFf1tUdGCImf5JtboKRTeAp32uvPjYR1Bbya8Yup6OuCrKDrdOdqKlULFp3H+
ia8W8hFCaGgvnpNveoBLFcMq6xxorQ4LhEcwnLABs9Y8UnL5Ao2ozijVA7Pkhdep
dt5CYmEq77bxpQT1tLUt9jp246gZgMQQDZAR6BW+fg3FCpXDWguxF+Xzuf7JuL9O
V2SKYTbdiljladNZO0sq566U6GJptKhl8pHlihkNyHc6jkQGxnzpzFolTUl66jbc
f9jO+f+R9C+FDT1fcPPIolYTBRCvYQ9B6c+olHVTNNYUmW36TThsbXiYeqQw4JPA
=Wn2x
-----END PGP PUBLIC KEY BLOCK-----
EOG
fi
curl -L "$url" > rpmfusion-nonfree.rpm
curl -L "${url/-release-/-release-tainted-}" > rpmfusion-nonfree-tainted.rpm
rpm --checksig rpmfusion-nonfree{,-tainted}.rpm
rpm --install rpmfusion-nonfree{,-tainted}.rpm
exec rm -f rpmfusion-nonfree{,-tainted}.rpm
EOF
}

# OPTIONAL (IMAGE)

function save_rpm_db() {
        opt selinux && echo /usr/lib/rpm-db /var/lib/rpm >> root/etc/selinux/targeted/contexts/files/file_contexts.subs
        mv root/var/lib/rpm root/usr/lib/rpm-db
        echo > root/usr/lib/tmpfiles.d/rpm-db.conf \
            'L /var/lib/rpm - - - - ../../usr/lib/rpm-db'

        # Define a service and timer to check when updates are available.
        test -x root/usr/bin/dnf || return 0
        cat << 'EOF' > root/usr/lib/systemd/system/image-update-check.service
[Unit]
Description=Write the MOTD with the system update status
After=network.target network-online.target
#Before=display-manager.service sshd.service  # Don't delay booting.
[Service]
ExecStart=/bin/bash -eo pipefail -c 'declare -A total=() ; \
for retry in 1 2 3 4 5 ; do while read -rs count type extra ; \
do [[ $$count =~ [0-9]+ ]] && total[$$type]=$$count || \
{ test "x$$count" = xError: && break ; } ; \
done < <(exec /usr/bin/dnf --quiet updateinfo summary --available 2>&1) ; \
test -n "$$count" && /usr/bin/sleep 10 || break ; done ; \
test -n "$$count" && exit 1 ; unset "total["{New,Moderate,Low}"]" ; \
/usr/bin/mkdir -pZ /run/motd.d ; exec > /run/motd.d/image-update-check ; \
test $${#total[@]} -gt 0 || exit 0 ; \
{ (( total[Critical] + total[Important] )) && echo -n UPDATES REQUIRED ; } || \
{ (( total[Security] )) && echo -n Security updates are available ; } || \
{ (( total[Bugfix] )) && echo -n Bug fixes are available ; } || \
echo -n Updates are available ; sec= ; \
(( total[Critical] )) && sec+=" ($${total[Critical]} critical)" ; \
(( total[Important] )) && { sec="$${sec/%?/, }" ; \
sec="${sec:- (}$${total[Important]} important)" ; } ; \
echo -n $${total[Security]:+, $${total[Security]} security$$sec} ; \
echo -n $${total[Bugfix]:+, $${total[Bugfix]} bugfix} ; \
echo -n $${total[Enhancement]:+, $${total[Enhancement]} enhancement} ; \
echo -n $${total[other]:+, $${total[other]} other}'
ExecStartPost=-/bin/bash -euo pipefail -c 'test -x /usr/bin/dconf || exit 0 ; \
test -s /etc/dconf/db/gdm.d/01-banner -a -s /run/motd.d/image-update-check && \
echo -e > /etc/dconf/db/gdm.d/02-banner "[org/gnome/login-screen]\n\
banner-message-text=\'$(</run/motd.d/image-update-check)\'" || \
/usr/bin/rm -f /etc/dconf/db/gdm.d/02-banner ; \
exec /usr/bin/dconf update'
TimeoutStartSec=5m
Type=oneshot
[Install]
WantedBy=multi-user.target
EOF
        cat << 'EOF' > root/usr/lib/systemd/system/image-update-check.timer
[Unit]
Description=Check for system update notifications twice daily
[Timer]
AccuracySec=1h
OnUnitInactiveSec=12h
[Install]
WantedBy=timers.target
EOF

        # Show the status message on GDM if it exists.
        if test -x root/usr/sbin/gdm
        then
                mkdir -p root/etc/dconf/db/gdm.d root/etc/dconf/profile
                cat << 'EOF' > root/etc/dconf/db/gdm.d/01-banner
[org/gnome/login-screen]
banner-message-enable=true
EOF
                cat << 'EOF' > root/etc/dconf/profile/gdm
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF
        fi

        # Only enable the units if explicitly requested.
        if test "x$*" = x+updates
        then
                ln -fst root/usr/lib/systemd/system/timers.target.wants \
                    ../image-update-check.timer
                ln -fst root/usr/lib/systemd/system/multi-user.target.wants \
                    ../image-update-check.service
        fi
}

function drop_package() while read -rs
do exclude_paths+=("${REPLY#/}")
done < <(rpm --root="$PWD/root" -qal "$@")

# WORKAROUNDS

# The Fedora 30 implementation is preserved separately for i686 support.
test "x${options[release]-}" != x30 || . legacy/fedora30.sh
