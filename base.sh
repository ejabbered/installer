disk=ext4.img
exclude_paths=({boot,dev,home,media,proc,run,srv,sys,tmp}/'*')

declare -A options
options[distro]=fedora
options[bootable]=   # Include a kernel and init system to boot the image
options[iptables]=   # Configure a strict firewall by default
options[networkd]=   # Enable minimal DHCP networking without NetworkManager
options[nspawn]=     # Create an executable file that runs in nspawn
options[partuuid]=   # The partition UUID for verity to map into the root FS
options[ramdisk]=    # Produce an initrd that sets up the root FS in memory
options[read_only]=  # Use tmpfs in places to make a read-only system usable
options[selinux]=    # Enforce SELinux policy
options[squash]=     # Produce a compressed squashfs image
options[uefi]=       # Generate a single UEFI executable containing boot files
options[verity]=     # Prevent file system modification with dm-verity

function usage() {
        echo "Usage: $0 [-BKRSUVZhu] \
[-E <uefi-binary-path>] [[-I] -P <partuuid>] \
<config.sh> [<parameter>]...

This program will produce a root file system from a given system configuration
file.  Parameters after the configuration file are passed to it, so their
meanings are specific to each system (typically listing paths for host files to
be copied into the target file system).

The output options described below can change or ammend the produced files, but
the configuration file can forcibly enable them to declare they are a required
part of the system, or disable them to declare they are incompatible with it.

Output format options:
  -B    Include a kernel and init program to produce a bootable system.
  -K    Bundle the root file system in the initrd to run in RAM (implying -B).
  -R    Make the system run in read-only mode with tmpfs mounts where needed.
  -S    Use squashfs as the root file system for compression (implying -R).
  -U    Generate a UEFI executable that boots into the system (implying -B).
  -V    Attach verity signatures to the root file system image (implying -R).
  -Z    Install and enforce targeted SELinux policy, and label the file system.

Install options:
  -E <uefi-binary-path>
        Save the UEFI executable to the given path, which should be on the
        mounted target ESP file system (implying -U).
        Example: -E /boot/EFI/BOOT/BOOTX64.EFI
  -I    Install the file system to disk on the partition specified with -P.
  -P <partuuid>
        Configure the kernel arguments to use the given GPT partition UUID as
        the root file system on boot.  If this option is not used, the kernel
        will assume that the root file system is on /dev/sda.
        Example: -P e08ede5f-56d4-4d6d-b8d9-abf7ef5be608

Help options:
  -h    Output this help text.
  -u    Output a single line of brief usage syntax."
}

function imply_options() {
        opt squash || opt verity && options[read_only]=1
        opt uefi_path && options[uefi]=1
        opt uefi || opt ramdisk && options[bootable]=1
        opt distro || options[distro]=fedora  # This can't be unset.
}

function validate_options() {
        # Validate form, but don't look for a device yet (because hot-plugging exists).
        opt partuuid &&
        [[ ${options[partuuid]} =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]]
        # A partition is required when writing to disk.
        opt install_to_disk && opt partuuid
        # A UEFI executable is required in order to save it.
        opt uefi_path && opt uefi
        return 0
}

function opt() { test -n "${options["${*?}"]-}" ; }

function enter() {
        $nspawn \
            --bind="$output:/wd" \
            ${loop:+--bind="$loop:/dev/loop-root"} \
            --chdir=/wd \
            --directory="$buildroot" \
            --machine="buildroot-${output##*.}" \
            --quiet \
            "$@"
}

function customize_buildroot() { : ; }
function customize() { : ; }

function create_root_image() {
        $truncate --size="${1:-1G}" "$output/$disk"
        declare -g loop=$($losetup --show --find "$output/$disk")
        trap -- "$losetup --detach $loop" EXIT
}

function mount_root() {
        mkfs.ext4 -m 0 /dev/loop-root
        mkdir -p root  # CentOS 7
        mount /dev/loop-root root ; trap -- 'umount root' EXIT
}

function relabel() {
        setfiles -vFr root \
            root/etc/selinux/targeted/contexts/files/file_contexts root
}

function unmount_root() {
        e4defrag root
        umount root ; trap - EXIT
        opt read_only && tune2fs -O read-only /dev/loop-root || :  # CentOS 7
        e2fsck -Dfy /dev/loop-root || [ "$?" -eq 1 ]
}

function squash() {
        local -r IFS=$'\n' xattrs=-$(opt selinux || echo no-)xattrs
        disk=squash.img
        mksquashfs root "$disk" -noappend "$xattrs" \
            -comp zstd -Xcompression-level 22 \
            -wildcards -ef /dev/stdin <<< "${exclude_paths[*]}"
}

function verity() {
        local -r dev=${options[partuuid]:+PARTUUID=${options[partuuid]}}
        local -ir size=$(stat --format=%s "$disk")
        local -A verity
        ! (( size % 4096 ))

        while read
        do verity[${REPLY%%:*}]=${REPLY#*:}
        done < <(veritysetup format "$disk" signatures.img)

        echo > kernel_args.txt \
            ro root=/dev/dm-0 \
            dm-mod.create='"'root,,,ro,0 $(( size / 512 )) \
                verity ${verity[Hash type]} ${dev:-/dev/sda} ${dev:-/dev/sda} \
                ${verity[Data block size]} ${verity[Hash block size]} \
                ${verity[Data blocks]} $(( ${verity[Data blocks]} + 1 )) \
                ${verity[Hash algorithm]} ${verity[Root hash]} \
                ${verity[Salt]} 0'"'
        cat "$disk" signatures.img > final.img
}

function build_ramdisk() {
        local -r root=$(mktemp --directory --tmpdir="$PWD" ramdisk.XXXXXXXXXX)
        mkdir -p "$root"/{usr/lib/systemd/system/initrd-root-fs.target.requires,sysroot}
        cat << EOF > "$root/usr/lib/systemd/system/sysroot.mount"
[Unit]
Before=initrd-root-fs.target
[Mount]
What=/sysroot/root.img
Where=/sysroot
Type=$(opt squash && echo squashfs || echo ext4)
Options=loop$(opt read_only && echo ,ro)
EOF
        ln -fst "$root/usr/lib/systemd/system/initrd-root-fs.target.requires" ../sysroot.mount
        ln -fn final.img "$root/sysroot/root.img"
        find "$root" -mindepth 1 -printf '%P\n' |
        { cd "$root" ; cpio -R 0:0 -co ; } |  # CentOS 7
        xz --check=crc32 -9e | cat initrd.img - > ramdisk.img
}

function configure_dhcp() if opt networkd
then
        mkdir -p root/usr/lib/systemd/system/network-online.target.wants
        ln -fst root/usr/lib/systemd/system/multi-user.target.wants \
            ../systemd-networkd.service ../systemd-resolved.service
        ln -fst root/usr/lib/systemd/system/network-online.target.wants \
            ../systemd-networkd-wait-online.service
        cat << 'EOF' > root/usr/lib/systemd/network/99-dhcp.network
[Network]
DHCP=yes

[DHCP]
UseDomains=yes
UseMTU=yes
EOF
        ln -fst root/etc ../run/systemd/resolve/resolv.conf
elif test -s root/usr/lib/systemd/system/NetworkManager.service
then
        mkdir -p root/usr/lib/systemd/system/network-online.target.wants
        ln -fst root/usr/lib/systemd/system/multi-user.target.wants \
            ../NetworkManager.service
        ln -fst root/usr/lib/systemd/system/network-online.target.wants \
            ../NetworkManager-wait-online.service
fi

function configure_iptables() {
        mkdir -p root/usr/lib/systemd/system/basic.target.wants
        ln -fst root/usr/lib/systemd/system/basic.target.wants \
            ../iptables.service ../ip6tables.service
        cat << 'EOF' > root/etc/sysconfig/iptables
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
COMMIT
EOF
        cat << 'EOF' > root/etc/sysconfig/ip6tables
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
COMMIT
EOF
}

function local_login() {
        sed -i -e 's/^root:[^:]*/root:/' root/etc/shadow

        cat << 'EOF' > root/etc/vconsole.conf
FONT="eurlatgr"
KEYMAP="emacs2"
EOF

        mkdir -p root/usr/lib/systemd/system/getty.target.wants
        ln -fns ../getty@.service \
            root/usr/lib/systemd/system/getty.target.wants/getty@tty1.service
}

function tmpfs_var() {
        exclude_paths+=(var/'*')

        mkdir -p root/usr/lib/systemd/system
        cat << 'EOF' > root/usr/lib/systemd/system/var.mount
[Unit]
Description=Mount writeable tmpfs over /var
ConditionPathIsMountPoint=!/var

[Mount]
What=tmpfs
Where=/var
Type=tmpfs
Options=rootcontext=system_u:object_r:var_t:s0,mode=0755,strictatime,nodev,nosuid

[Install]
WantedBy=local-fs.target
EOF
}

function tmpfs_home() {
        cat << 'EOF' > root/usr/lib/systemd/system/home.mount
[Unit]
Description=Mount tmpfs over /home to create new users
ConditionPathIsMountPoint=!/home
ConditionPathIsSymbolicLink=!/home

[Mount]
What=tmpfs
Where=/home
Type=tmpfs
Options=rootcontext=system_u:object_r:home_root_t:s0,mode=0755,strictatime,nodev,nosuid

[Install]
WantedBy=local-fs.target
EOF

        cat << 'EOF' > root/usr/lib/systemd/system/root.mount
[Unit]
Description=Mount tmpfs over /root
ConditionPathIsMountPoint=!/root
ConditionPathIsSymbolicLink=!/root

[Mount]
What=tmpfs
Where=/root
Type=tmpfs
Options=rootcontext=system_u:object_r:admin_home_t:s0,mode=0700,strictatime,nodev,nosuid

[Install]
WantedBy=local-fs.target
EOF

        mkdir -p root/usr/lib/systemd/system/local-fs.target.wants
        ln -fst root/usr/lib/systemd/system/local-fs.target.wants \
            ../home.mount ../root.mount

        test -s root/etc/pam.d/system-auth &&
        echo >> root/etc/pam.d/system-auth \
            'session     required      pam_mkhomedir.so'

        cat << 'EOF' > root/usr/lib/tmpfiles.d/root.conf
C /root - - - - /etc/skel
Z /root
EOF
}

function overlay_etc() {
        cat << 'EOF' > root/usr/lib/systemd/system/etc-overlay-setup.service
[Unit]
Description=Set up overlay working directories for /etc in /run
DefaultDependencies=no
RequiresMountsFor=/run

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mkdir -Zpm 0755 /run/etcgo/overlay /run/etcgo/wd
ExecStartPost=-/usr/bin/chcon -t etc_t /run/etcgo/overlay
EOF

        cat << 'EOF' > root/usr/lib/systemd/system/etc.mount
[Unit]
Description=Mount a writeable overlay over /etc
ConditionPathIsMountPoint=!/etc
After=etc-overlay-setup.service
Requires=etc-overlay-setup.service

[Mount]
What=overlay
Where=/etc
Type=overlay
Options=strictatime,nodev,nosuid,lowerdir=/etc,upperdir=/run/etcgo/overlay,workdir=/run/etcgo/wd

[Install]
RequiredBy=local-fs.target
EOF
        ln -fst root/usr/lib/systemd/system/local-fs.target.wants ../etc.mount

        # Probably should just delete this workaround until it's implemented for real in the initrd.
        if test -x root/usr/bin/git
        then
                mkdir -p root/usr/lib/systemd/system-generators
                cat << 'EOF' > root/usr/lib/systemd/system-generators/etcgo
#!/bin/sh -e
set -euxo pipefail

# Create overlay upper directories for /etc.
mountpoint -q /run
mkdir -Zpm 0755 /run/etcgo/overlay /run/etcgo/wd
chcon -t etc_t /run/etcgo/overlay || :

# If /var is not mounted already, make it use tmpfs to get a usable system.
mountpoint -q /var ||
mount -t tmpfs -o rootcontext=system_u:object_r:var_t:s0,mode=0755,strictatime,nodev,nosuid tmpfs /var

# Create the Git database for the /etc overlay in /var if it doesn't exist.
if ! test -d /var/lib/etcgo
then
        mkdir -Zpm 0750 /var/lib/etcgo
        git -C /var/lib/etcgo init --bare
        echo 'System configuration overlay tracker' > /var/lib/etcgo/description
        echo -e '[user]\n\tname = root\n\temail = root@localhost' >> /var/lib/etcgo/config
        git -C /var/lib/etcgo --work-tree=../../../run/etcgo/overlay commit --allow-empty --message='Repository created'
fi

# Check out the overlay files, and mount it over /etc with correct labels.
git -C /var/lib/etcgo worktree add --force -B master ../../../run/etcgo/overlay master
mount -t overlay -o strictatime,nodev,nosuid,lowerdir=/etc,upperdir=/run/etcgo/overlay,workdir=/run/etcgo/wd overlay /etc
restorecon -vFR /etc /var/lib/etcgo || :
EOF
                chmod 0755 root/usr/lib/systemd/system-generators/etcgo
        fi
}

function configure_system() {
        exclude_paths+=(etc/systemd/system/'*')

        test -s root/usr/lib/systemd/system/gdm.service &&
        ln -fns gdm.service root/usr/lib/systemd/system/display-manager.service

        test -s root/usr/lib/systemd/system/display-manager.service &&
        ln -fns graphical.target root/usr/lib/systemd/system/default.target ||
        ln -fns multi-user.target root/usr/lib/systemd/system/default.target

        test -s root/usr/lib/systemd/system/dbus.service ||
        ln -fns dbus-broker.service root/usr/lib/systemd/system/dbus.service

        test -s root/etc/systemd/logind.conf &&
        sed -i \
            -e 's/^[# ]*\(HandleLidSwitch\)=.*/\1=ignore/' \
            -e 's/^[# ]*\(KillUserProcesses\)=.*/\1=yes/' \
            root/etc/systemd/logind.conf

        test -s root/usr/lib/systemd/system/sshd.service &&
        ln -fst root/usr/lib/systemd/system/multi-user.target.wants ../sshd.service

        test -s root/etc/ssh/sshd_config &&
        sed -i -e 's/^[# ]*\(PermitEmptyPasswords\|PermitRootLogin\) .*/\1 no/' root/etc/ssh/sshd_config

        test -s root/etc/sudoers &&
        sed -i -e '/%wheel/{s/^[# ]*/# /;/NOPASSWD/s/^[# ]*//;}' root/etc/sudoers

        test -x root/usr/libexec/upowerd &&
        echo 'd /var/lib/upower' > root/usr/lib/tmpfiles.d/upower.conf

        test -d root/usr/share/themes/Emacs/gtk-3.0 &&
        mkdir -p root/etc/gtk-3.0 && cat << 'EOF' > root/etc/gtk-3.0/settings.ini
[Settings]
gtk-application-prefer-dark-theme = true
gtk-button-images = true
gtk-key-theme-name = Emacs
gtk-menu-images = true
EOF

        test -x root/usr/bin/emacs -o -h root/usr/bin/emacs &&
        (cd root/etc/skel
                cat << 'EOF' > .emacs
; Enable the Emacs package manager.
(require 'package)
(add-to-list 'package-archives '("melpa" . "http://melpa.org/packages/") t)
(package-initialize)
; Efficiency
(menu-bar-mode 0)
(fset 'yes-or-no-p 'y-or-n-p)
(setq gc-cons-threshold 10485760)
(setq kill-read-only-ok t)
; Cleanliness
(setq-default indent-tabs-mode nil)
(setq backup-inhibited t)
(setq auto-save-default nil)
; Time
(setq display-time-day-and-date t)
(setq display-time-24hr-format t)
(display-time-mode 1)
; Place
(setq line-number-mode t)
(setq column-number-mode t)
EOF
                echo export EDITOR=emacs >> .bash_profile
        )

        test -d root/usr/lib*/firefox/browser/defaults/preferences &&
        (cd root/usr/lib*/firefox/browser/defaults/preferences
                cat << 'EOF' > privacy.js
// Opt out of allowing Mozilla to install random studies.
pref("app.shield.optoutstudies.enabled", false);
// Disable the beacon API for analytical trash.
pref("beacon.enabled", false);
// Don't recommend things.
pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
// Disable spam-tier nonsense on new tabs.
pref("browser.newtabpage.enabled", false);
// Don't send information to Mozilla.
pref("datareporting.healthreport.uploadEnabled", false);
// Never give up laptop battery information.
pref("dom.battery.enabled", false);
// Remove useless Pocket stuff.
pref("extensions.pocket.enabled", false);
// Never send location data.
pref("geo.enabled", false);
// Send DNT all the time.
pref("privacy.donottrackheader.enabled", true);
// Prevent various cross-domain tracking methods.
pref("privacy.firstparty.isolate", true);
// Never try to save credentials.
pref("signon.rememberSignons", false);
EOF
                cat << 'EOF' > usability.js
// Fix the Ctrl+Tab behavior.
pref("browser.ctrlTab.recentlyUsedOrder", false);
// Never open more browser windows.
pref("browser.link.open_newwindow.restriction", 0);
// Include a sensible search bar.
pref("browser.search.openintab", true);
pref("browser.search.suggest.enabled", false);
pref("browser.search.widget.inNavBar", true);
// Restore sessions instead of starting at home, and make the home page blank.
pref("browser.startup.homepage", "about:blank");
pref("browser.startup.page", 3);
// Fit more stuff on the screen.
pref("browser.tabs.drawInTitlebar", true);
pref("browser.uidensity", 1);
// Stop hiding protocols.
pref("browser.urlbar.trimURLs", false);
// Enable some mildly useful developer tools.
pref("devtools.command-button-rulers.enabled", true);
pref("devtools.command-button-scratchpad.enabled", true);
pref("devtools.command-button-screenshot.enabled", true);
// Make the developer tools frame match the browser theme.
pref("devtools.theme", "dark");
// Display when messages are logged.
pref("devtools.webconsole.timestampMessages", true);
// Shut up.
pref("general.warnOnAboutConfig", false);
// Make widgets on web pages match the rest of the desktop.
pref("widget.content.allow-gtk-dark-theme", true);
EOF
        )

        test -x root/usr/bin/vlc && mkdir -p root/etc/skel/.config/vlc &&
        (cd root/etc/skel/.config/vlc
                cat << 'EOF' > vlc-qt-interface.conf
[MainWindow]
MainToolbar1="64;64;38;65"
MainToolbar2="0-2;64;3;1;4;64;7;9;64;10;20;19;64-4;39;37;65;35-4;"
adv-controls=4
EOF
                cat << 'EOF' > vlcrc
[qt]
qt-privacy-ask=0
[core]
metadata-network-access=0
EOF
        )

        test -d root/usr/lib/locale/en_US.utf8 &&
        echo 'LANG="en_US.UTF-8"' > root/etc/locale.conf

        ln -fns ../usr/share/zoneinfo/America/New_York root/etc/localtime

        # WORKAROUNDS

        echo d /var/spool/mail 0775 root mail > root/usr/lib/tmpfiles.d/mail.conf

        mkdir -p root/usr/lib/systemd/system/systemd-random-seed.service.d
        cat << 'EOF' > root/usr/lib/systemd/system/systemd-random-seed.service.d/mkdir.conf
# SELinux prevents the service from creating the directory before tmpfiles.
[Service]
ExecStartPre=-/usr/bin/mkdir -p /var/lib/systemd
ExecStartPre=-/usr/sbin/restorecon -vFR /var
EOF
}

function produce_uefi_exe() {
        local -r kargs=$(test -s kernel_args.txt && echo kernel_args.txt)
        local -r logo=$(test -s logo.bmp && echo logo.bmp)
        local initrd=$(opt ramdisk && echo ramdisk || echo initrd).img
        test -e "$initrd" || initrd=

        objcopy \
            --add-section .osrel=root/etc/os-release --change-section-vma .osrel=0x20000 \
            ${kargs:+--add-section .cmdline="$kargs" --change-section-vma .cmdline=0x30000} \
            ${logo:+--add-section .splash="$logo" --change-section-vma .splash=0x40000} \
            --add-section .linux=vmlinuz --change-section-vma .linux=0x2000000 \
            ${initrd:+--add-section .initrd="$initrd" --change-section-vma .initrd=0x3000000} \
            /usr/lib/systemd/boot/efi/linuxx64.efi.stub BOOTX64.EFI
}

function produce_nspawn_exe() {
        local -ir bs=512 start=2048
        local -i size=$(stat --format=%s final.img)
        (( size % bs )) && size+=$(( bs - size % bs ))

        truncate --size=$(( size + (start + 33) * bs )) nspawn.img
        echo g \
            n 1 $start $(( size / bs + start - 1 )) \
            t 0fc63daf-8483-4772-8e79-3d69d8477de4 \
            w | tr ' ' '\n' | fdisk nspawn.img

        echo $'\nTHE_PARTITION_TABLE_HAS_ENDED_SO_HERE_IS_THE_SCRIPT_TO_RUN' |
        cat - launch.sh |
        dd bs=$bs conv=notrunc of=nspawn.img seek=34
        dd bs=$bs conv=notrunc if=final.img of=nspawn.img seek=$start

        dd bs=$bs conv=notrunc of=nspawn.img << 'EOF'
#!/bin/bash -eu
IMAGE=$(readlink /proc/$$/fd/255)
: << 'THE_PARTITION_TABLE_HAS_ENDED_SO_HERE_IS_THE_SCRIPT_TO_RUN'
EOF
        chmod 0755 nspawn.img
}

# OPTIONAL (IMAGE)

function store_home_on_var() {
        opt selinux && echo /var/home /home >> root/etc/selinux/targeted/contexts/files/file_contexts.subs
        mv root/home root/var/home ; ln -fns var/home root/home
        test "x${options[distro]}" = xcentos && echo 'd /var/home 0755' > root/usr/lib/tmpfiles.d/home.conf ||  # CentOS 7
        echo 'Q /var/home 0755' > root/usr/lib/tmpfiles.d/home.conf
        if test "x$*" = x+root
        then
                mv root/root root/var/roothome ; ln -fns var/roothome root/root
                cat << 'EOF' > root/usr/lib/tmpfiles.d/root.conf
C /var/roothome 0700 root root - /etc/skel
Z /var/roothome
EOF
        fi
}

function wine_gog_script() {
        local -r app="Z:${1//\//\\}"
        local -A typemap=()
        typemap[dword]=REG_DWORD
        typemap[string]=REG_SZ

        jq -cr '.actions[].install|select(.action=="setRegistry").arguments' |
        while read
        do
                local -A r=()

                while read -r
                do
                        REPLY=${REPLY:1:-1}
                        k=${REPLY%%:*} ; k=${k//\"/}
                        v=${REPLY#*:} ; v=${v#\"} ; v=${v%\"}
                        r[${k:-_}]=$v
                done <<< "${REPLY//,/$'\n'}"

                case "${r[valueType]}" in
                    string) r[valueData]=${r[valueData]//{app\}/$app} ;;
                    dword) r[valueData]=${r[valueData]/#\$/0x} ;;
                esac

                echo wine reg add \
                    "'${r[root]//\"/}\\${r[subkey]//\"/}'" \
                    /v "${r[valueName]//\"/}" \
                    /t "${typemap[${r[valueType]}]}" \
                    /d "'${r[valueData]}'" /f
        done
}
