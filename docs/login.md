# Connecting to the KI development VM

Connect to the MET VPN, then run `./startKIVM.sh` from this repository on your laptop. The script checks the VM and its SSH host key, waits for provisioning to finish, starts the code-server tunnel, and opens an SSH shell.

## First login

After the VM has finished provisioning, its first interactive login asks you to set a password. This password is used for `sudo`, root access, and RDP on the VM. Enter it at the VM prompt; the first-login session then ends automatically. `startKIVM.sh` checks that a normal shell is available and continues into the regular SSH session.

If the first-login session ends but the script reports that a normal shell is not ready, run `./startKIVM.sh` again from a terminal. Do not recreate the VM just because this one-time login step was interrupted.

## Later logins

Run `./startKIVM.sh` again to reconnect. The VM password is not the code-server password: the script prints the code-server URL and its password before opening the shell. Open that URL in your laptop browser while the script is running; the SSH tunnel is local to your laptop.

The generated `kiwm` SSH alias can also open a shell directly if `~/.ssh/config` includes `~/.ssh/config.d/ki.conf`. Use `./startKIVM.sh` when you need the code-server tunnel.

The VM is deleted during the weekly Monday wipe. After a wipe, run the script to create and provision a replacement, verify the displayed host-key fingerprint, and complete first login again. VM files and its login password do not carry over.