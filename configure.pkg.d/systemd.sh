# Unit configuration should happen in /usr while building the image.
rm -fr root/etc/systemd/system/*

# Ignore the laptop lid, and kill all user processes on logout.
test -s root/etc/systemd/logind.conf &&
sed -i \
    -e 's/^[# ]*\(HandleLidSwitch\)=.*/\1=ignore/' \
    -e 's/^[# ]*\(KillUserProcesses\)=.*/\1=yes/' \
    root/etc/systemd/logind.conf

# Always start a login prompt on tty1.
mkdir -p root/usr/lib/systemd/system/getty.target.wants
ln -fns ../getty@.service \
    root/usr/lib/systemd/system/getty.target.wants/getty@tty1.service

# Configure a default font and keymap for the console.
rm -f root/etc/vconsole.conf
compgen -G 'root/lib/kbd/consolefonts/eurlatgr.*' &&
echo 'FONT="eurlatgr"' >> root/etc/vconsole.conf
compgen -G 'root/lib/kbd/keymaps/legacy/i386/qwerty/emacs2.*' &&
echo 'KEYMAP="emacs2"' >> root/etc/vconsole.conf

# Select a preferred display manager when it is installed.
test -s root/usr/lib/systemd/system/gdm.service &&
ln -fns gdm.service root/usr/lib/systemd/system/display-manager.service

# Define a default target on boot.
test -s root/usr/lib/systemd/system/display-manager.service &&
ln -fns graphical.target root/usr/lib/systemd/system/default.target ||
ln -fns multi-user.target root/usr/lib/systemd/system/default.target

# Use systemd to configure networking and DNS when requested.
if opt networkd
then
        mkdir -p root/usr/lib/systemd/system/multi-user.target.wants
        ln -fst root/usr/lib/systemd/system/multi-user.target.wants \
            ../systemd-networkd.service ../systemd-resolved.service

        # Make the network-online.target unit functional.
        mkdir -p root/usr/lib/systemd/system/network-online.target.wants
        ln -fst root/usr/lib/systemd/system/network-online.target.wants \
            ../systemd-networkd-wait-online.service

        # Have all unconfigured network interfaces default to DHCP.
        cat << 'EOF' > root/usr/lib/systemd/network/99-dhcp.network
[Network]
DHCP=yes

[DHCP]
UseDomains=yes
UseMTU=yes
EOF

        # Point DNS configuration at resolved's DHCP settings (not the stub).
        ln -fst root/etc ../run/systemd/resolve/resolv.conf
fi