# Set up the laptop

1. Review the README, manifests, and laptop profile. If needed, copy
   `profiles/laptop/profile.env.example` to `profiles/laptop/profile.env` and
   set the optional RDP endpoint or trusted NetworkManager connection UUIDs.

2. Preview the setup:

   ```sh
   bash install.sh --dry-run --replace-dotfiles
   ```

3. Start the installation:

   ```sh
   bash install.sh --replace-dotfiles
   ```

   To enable the system-wide key remap, add `--enable-keyd` to both commands.
   It affects every keyboard. `keyd` is layered either way; the flag configures
   and activates the remap. Use `--replace-system` only if you intend to back
   up and replace a conflicting keyd configuration.

   If package installation stages an rpm-ostree deployment, the installer exits
   with status `10`. Reboot, then rerun the same command with the same options.

4. After setup, enable Tailscale SSH:

   ```sh
   sudo tailscale up --ssh
   ```

5. In Niri, check the display names and edit the generated local output config:

   ```sh
   niri msg outputs
   # Edit ~/.config/niri/local.kdl with the actual output identifiers.
   ```

6. If you want the battery charge cap, enable **Noctalia Control Center → Power
   → Use charge thresholds**. Check the installation:

   ```sh
   rpm-ostree status
   bash scripts/verify.sh --profile laptop
   ```

The installer runs verification at the end. See the README for hardware
behavior, services, recovery, and other details.
