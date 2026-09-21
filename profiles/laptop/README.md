# Laptop Profile

This profile holds settings specific to the laptop while shared defaults remain
portable. Copy `profile.env.example` to `profile.env` and set only values that
apply to this machine. `profile.env` is ignored because host names and user
names can be sensitive; credentials and tokens must be stored in a secret
manager, never here.

The installer links an existing `profile.env` to
`~/.config/fedora-laptop/profile.env`; the Bash profile loads it automatically.

## Optional RDP Target

`FEDORA_LAPTOP_RDP_HOST` and `FEDORA_LAPTOP_RDP_USER` identify a default remote endpoint. Leave either value
empty to disable that default. They are not credentials; the RDP client should
obtain passwords or keys at runtime from an appropriate credential store.

## Niri Outputs

The shared config includes `~/.config/niri/local.kdl` for machine-specific
output rules. The installer creates it once from `local.kdl.example` and
never overwrites it.

Do not guess connector names or copy a monitor rule from another laptop. In a
running Niri session, use:

```sh
niri msg outputs
```

Record the exact output identifier reported for the internal panel and any
docks or monitors, then add one `output` block per confirmed identifier to
`~/.config/niri/local.kdl`. Recheck them after display, dock, or driver
changes. Verification warns while the file is missing or still the stub.
