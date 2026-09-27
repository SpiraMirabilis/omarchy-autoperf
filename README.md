# Auto Performance for Omarchy

For large laptops with large fans!

A bar widget that switches to the **performance** power profile when CPU load
spikes, and drops back down once the machine has been quiet for a while.

Click the 󰓅 icon for the panel; right-click it to turn auto performance on or off.
The icon is dimmed while off and lights up in the accent color while boosted.

| Setting | Default | |
|---|---|---|
| Boost from | Balanced | Profiles that get boosted: Balanced, Power saver, or Both. Performance is never touched. |
| When CPU reaches | 60% | Total CPU usage that counts as a spike (two samples in a row, one second apart). |
| When CPU falls to | 10% | Usage that counts as idle. Always kept below the spike threshold. |
| For | 10 seconds | How long it has to stay idle before dropping back. |
| To | Previous | Drop back to the profile that was boosted, or always to Balanced / Power saver. |
| Only on AC power | On | Do nothing on battery and leave the profile to Omarchy. |

If you change the profile yourself while boosted, autoperf leaves your choice alone.
Stopping the daemon restores the saved Omarchy profile for the current power source.

## Install

```bash
omarchy plugin add https://github.com/SpiraMirabilis/omarchy-autoperf.git --enable
~/.config/omarchy/plugins/io.github.spiramirabilis.autoperf/setup
```

`omarchy plugin add` only clones the files. `setup` builds the small daemon
(Rust, standard library only; installs `rust` if `cargo` is missing) into
`~/.local/bin/autoperf` and adds the `autoperf.service` systemd user unit. The panel
also offers to run it. Run `setup` again after `omarchy plugin update`.

Remove the daemon with `setup --uninstall`, then `omarchy plugin remove io.github.spiramirabilis.autoperf`.

## How it works

`daemon/` samples `/proc/stat` once a second (every 5 seconds it only checks
the power source while paused on battery) and switches profiles through
power-profiles-daemon over D-Bus. Settings live in `~/.config/autoperf/config`:

```ini
boost_from=balanced   # balanced | power-saver | both
up=60                 # spike threshold, %
up_samples=2          # consecutive samples at/above `up`
idle=10               # idle threshold, %
idle_secs=10          # seconds idle before dropping back
drop_to=previous      # previous | balanced | power-saver
ac_only=true
interval=1            # seconds between samples
```

The panel rewrites this file and the daemon picks up changes within a second;
`up_samples` and `interval` are file-only. The daemon publishes its state
(`watching`, `boosted`, `paused`) to `$XDG_RUNTIME_DIR/autoperf/state` for the
bar icon. Logs: `journalctl --user -u autoperf -f`.

## Development

```bash
cargo test --manifest-path daemon/Cargo.toml
omarchy plugin validate .
```
