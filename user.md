# Ubuntu VPS Initial Setup: Switching from Root to Sudo User

This guide walks through creating a non-root user with `sudo` privileges, copying SSH keys, testing connection, and disabling direct `root` logins over SSH.

---

## Quick Reference Summary

| Step | Task | Command |
| :--- | :--- | :--- |
| **1. Create User** | Add an unprivileged user | `adduser <username>` |
| **2. Grant Sudo** | Add user to administrative group | `usermod -aG sudo <username>` |
| **3. Copy SSH Keys** | Transfer keys from root to new user | `rsync --archive --chown=<user>:<user> ~/.ssh /home/<user>/` |
| **4. Test Access** | Verify login in a new terminal session | `ssh <username>@<server_ip>` |
| **5. Harden SSH** | Disable direct root logins | `PermitRootLogin no` in `/etc/ssh/sshd_config` |

---

## Step 1: Create a New User Account

Logged in as `root` on your fresh VPS, create your new unprivileged user account (replace `sammy` with your desired username):

```bash
adduser sammy
```

You will be prompted to set and confirm a password. You can press `Enter` to skip the optional user information fields (Full Name, Room Number, etc.).

---

## Step 2: Grant Administrative Privileges (`sudo`)

Add the newly created user to the `sudo` group so you can execute administrative commands when necessary:

```bash
usermod -aG sudo sammy
```

---

## Step 3: Copy SSH Keys to the New User

If you log in using an SSH key pair, you must copy your `root` user's authorized keys to the new user's home directory.

### Option A: Automatic Copy (Recommended)
Run this command while still logged in as `root`:

```bash
rsync --archive --chown=sammy:sammy ~/.ssh /home/sammy/
```

### Option B: Manual Setup
Alternatively, switch to the new user and manually paste your public key:

```bash
# Switch to the new user
su - sammy

# Create .ssh directory with correct permissions
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Paste your public SSH key into authorized_keys
nano ~/.ssh/authorized_keys

# Set strict file permissions
chmod 600 ~/.ssh/authorized_keys
exit
```

---

## Step 4: Test Your New User Login

> **⚠️ CRITICAL:** Do not close your active `root` SSH session yet! Keep it open as a fallback in case there is a connection issue.

Open a **new terminal window** on your local machine and test logging in with your new user account:

```bash
ssh sammy@YOUR_VPS_IP
```

Once connected, test `sudo` access:

```bash
sudo apt update
```

If prompted, enter your user password. If the package list updates successfully, your user setup is complete and functional.

---

## Step 5: Disable Direct Root Login over SSH

To secure your VPS against brute-force attacks, disable direct root logins.

1. Open the SSH server configuration file:
   ```bash
   sudo nano /etc/ssh/sshd_config
   ```

2. Locate the line `PermitRootLogin` and update it to `no`:
   ```text
   PermitRootLogin no
   ```

3. Save the file (`Ctrl + O`, then `Enter`) and exit `nano` (`Ctrl + X`).

4. Restart the SSH service to apply changes:
   ```bash
   sudo systemctl restart ssh
   ```

---

## Post-Setup Verification Checklist

- [ ] Logged in via SSH as non-root user
- [ ] Confirmed `sudo` privilege execution
- [ ] Direct `root` SSH login blocked (`PermitRootLogin no`)
- [ ] Optional: Configured UFW firewall (`sudo ufw allow OpenSSH && sudo ufw enable`)
