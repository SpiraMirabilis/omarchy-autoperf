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

## Install

```bash
omarchy plugin add https://github.com/SpiraMirabilis/omarchy-autoperf.git --enable
```

That is all: the plugin is plain QML and runs inside the Omarchy shell.

Upgrading from 0.2, which ran a small Rust daemon as a systemd user unit: the
plugin removes that unit and binary on first load (only the files the old
`setup` marked as its own). Settings carry over.

## How it works

`Service.qml` is loaded once by the shell. It reads `/proc/stat` once a second
and switches profiles through Quickshell's in-process binding to
power-profiles-daemon, so there is no extra process and nothing to build.
While paused on battery it does not sample at all. Settings live in
`~/.config/omarchy-autoperf/config`:

```ini
enabled=true
boost_from=balanced   # balanced | power-saver | both
up=60                 # spike threshold, %
up_samples=2          # consecutive samples at/above `up`
idle=10               # idle threshold, %
idle_secs=10          # seconds idle before dropping back
drop_to=previous      # previous | balanced | power-saver
ac_only=true
interval=1            # seconds between samples
```

The panel rewrites this file and hand edits are picked up live; `up_samples`
and `interval` are file-only. An active boost is noted in
`$XDG_RUNTIME_DIR/omarchy-autoperf/boost` so it is still dropped after a shell
restart. Logs: `journalctl --user -t omarchy-shell -f | grep autoperf`.

## Development

```bash
node Model.test.js
omarchy plugin validate .
```
