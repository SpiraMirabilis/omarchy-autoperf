//! autoperf: switch to the `performance` power profile when CPU usage spikes,
//! and back down once the machine has been near idle for a while.
//!
//! Settings come from a small `key=value` file (written by the Omarchy panel)
//! that is re-read whenever it changes, so no restart is needed. The current
//! state is published to `$XDG_RUNTIME_DIR/omarchy-autoperf/state` for the bar icon.
//!
//! Standard library only. CPU usage comes from /proc/stat, AC state from sysfs,
//! and profile changes go through power-profiles-daemon via `busctl`, which is
//! only spawned when a switch is actually due.

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::process::{exit, Command};
use std::str::FromStr;
use std::thread::sleep;
use std::time::{Duration, SystemTime};

const USAGE: &str = "usage: autoperf [--config PATH] [--verbose]

  --config PATH    settings file (default $XDG_CONFIG_HOME/omarchy-autoperf/config)
  --verbose        log every sample

Settings file keys (all optional):
  boost_from=balanced     balanced | power-saver | both
  up=60                   boost when total CPU usage is at or above this %
  up_samples=2            ...for this many consecutive samples
  idle=10                 count a sample as idle at or below this %
  idle_secs=10            drop back after this many seconds of idle
  drop_to=previous        previous | balanced | power-saver
  ac_only=true            do nothing while on battery
  interval=1              seconds between samples";

// How often to check for AC (and settings changes) while paused on battery.
// No CPU sampling happens then.
const BATTERY_POLL: Duration = Duration::from_secs(5);

// power-profiles-daemon: bus name, object path, interface, property.
const PPD: [&str; 4] = [
    "org.freedesktop.UPower.PowerProfiles",
    "/org/freedesktop/UPower/PowerProfiles",
    "org.freedesktop.UPower.PowerProfiles",
    "ActiveProfile",
];

#[derive(Clone, Copy, PartialEq, Debug)]
enum BoostFrom {
    Balanced,
    PowerSaver,
    Both,
}

impl BoostFrom {
    fn includes(self, profile: &str) -> bool {
        match self {
            BoostFrom::Balanced => profile == "balanced",
            BoostFrom::PowerSaver => profile == "power-saver",
            BoostFrom::Both => profile == "balanced" || profile == "power-saver",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum DropTo {
    /// Whatever profile was active before the boost.
    Previous,
    Balanced,
    PowerSaver,
}

impl DropTo {
    fn target(self, previous: &str) -> String {
        match self {
            DropTo::Previous => previous.to_string(),
            DropTo::Balanced => "balanced".to_string(),
            DropTo::PowerSaver => "power-saver".to_string(),
        }
    }
}

#[derive(Clone, PartialEq, Debug)]
struct Config {
    boost_from: BoostFrom,
    up: f64,
    up_samples: u32,
    idle: f64,
    idle_secs: u64,
    drop_to: DropTo,
    ac_only: bool,
    interval: u64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            boost_from: BoostFrom::Balanced,
            up: 60.0,
            up_samples: 2,
            idle: 10.0,
            idle_secs: 10,
            drop_to: DropTo::Previous,
            ac_only: true,
            interval: 1,
        }
    }
}

fn set<T: FromStr>(slot: &mut T, val: &str) -> bool {
    val.parse().map(|v| *slot = v).is_ok()
}

impl Config {
    /// Parse a settings file. Unknown keys and bad values are logged and
    /// skipped, leaving the default for that setting.
    fn parse(text: &str) -> Config {
        let d = Config::default();
        let mut c = d.clone();

        for (n, raw) in text.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let ok = match line.split_once('=').map(|(k, v)| (k.trim(), v.trim())) {
                Some(("boost_from", v)) => match v {
                    "balanced" => Some(BoostFrom::Balanced),
                    "power-saver" => Some(BoostFrom::PowerSaver),
                    "both" => Some(BoostFrom::Both),
                    _ => None,
                }
                .map(|b| c.boost_from = b)
                .is_some(),
                Some(("drop_to", v)) => match v {
                    "previous" => Some(DropTo::Previous),
                    "balanced" => Some(DropTo::Balanced),
                    "power-saver" => Some(DropTo::PowerSaver),
                    _ => None,
                }
                .map(|t| c.drop_to = t)
                .is_some(),
                Some(("up", v)) => set(&mut c.up, v),
                Some(("up_samples", v)) => set(&mut c.up_samples, v),
                Some(("idle", v)) => set(&mut c.idle, v),
                Some(("idle_secs", v)) => set(&mut c.idle_secs, v),
                Some(("ac_only", v)) => set(&mut c.ac_only, v),
                Some(("interval", v)) => set(&mut c.interval, v),
                _ => false,
            };
            if !ok {
                eprintln!("config line {}: ignoring {line:?}", n + 1);
            }
        }

        if !(0.0..=100.0).contains(&c.up) {
            eprintln!("config: up must be 0-100, using {}", d.up);
            c.up = d.up;
        }
        if !(0.0..c.up).contains(&c.idle) {
            let idle = if d.idle < c.up { d.idle } else { 0.0 };
            eprintln!("config: idle must be below up ({}), using {idle}", c.up);
            c.idle = idle;
        }
        c.up_samples = c.up_samples.max(1);
        c.interval = c.interval.max(1);
        c
    }

    fn describe(&self) -> String {
        format!(
            "boost {:?} at >={}% for {} sample(s); drop to {:?} after {}s at <={}%; {}",
            self.boost_from,
            self.up,
            self.up_samples,
            self.drop_to,
            self.idle_secs,
            self.idle,
            if self.ac_only { "AC only" } else { "AC and battery" }
        )
    }
}

/// The settings file, re-read whenever its modification time changes.
struct ConfigFile {
    path: PathBuf,
    seen: Option<Option<SystemTime>>,
}

impl ConfigFile {
    /// A freshly parsed config on the first call and whenever the file has
    /// changed (or appeared, or gone away) since the last call.
    fn poll(&mut self) -> Option<Config> {
        let mtime = fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        if self.seen == Some(mtime) {
            return None;
        }
        self.seen = Some(mtime);
        Some(Config::parse(&fs::read_to_string(&self.path).unwrap_or_default()))
    }
}

/// `$XDG_RUNTIME_DIR/omarchy-autoperf/state`, rewritten only when the state changes.
struct StateFile {
    path: Option<PathBuf>,
    last: String,
}

impl StateFile {
    fn new() -> Self {
        let path = std::env::var_os("XDG_RUNTIME_DIR")
            .map(|dir| PathBuf::from(dir).join("omarchy-autoperf/state"));
        StateFile { path, last: String::new() }
    }

    fn publish(&mut self, mode: &Mode, paused: bool) {
        let text = match mode {
            _ if paused => "state=paused\n".to_string(),
            Mode::Loaded { restore: Some(to) } => format!("state=boosted\nrestore={to}\n"),
            _ => "state=watching\n".to_string(),
        };
        if text == self.last {
            return;
        }
        let Some(path) = &self.path else { return };
        // Written in place rather than renamed over, so a file watcher on it
        // keeps working.
        let written = path.parent().is_some_and(|dir| fs::create_dir_all(dir).is_ok())
            && fs::write(path, &text).is_ok();
        if !written {
            eprintln!("cannot write {}", path.display());
        }
        self.last = text;
    }
}

struct Args {
    config: PathBuf,
    verbose: bool,
}

fn die(msg: &str) -> ! {
    eprintln!("autoperf: {msg}\n\n{USAGE}");
    exit(2)
}

fn default_config_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| die("neither XDG_CONFIG_HOME nor HOME is set"));
    base.join("omarchy-autoperf/config")
}

fn parse_args() -> Args {
    let mut config = None;
    let mut verbose = false;

    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--config" => {
                let path = args.next().unwrap_or_else(|| die("--config needs a value"));
                config = Some(PathBuf::from(path));
            }
            "-v" | "--verbose" => verbose = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                exit(0)
            }
            _ => die(&format!("unknown option: {flag}")),
        }
    }

    Args { config: config.unwrap_or_else(default_config_path), verbose }
}

/// Total CPU usage from the aggregate `cpu` line of /proc/stat.
struct CpuStat {
    file: File,
    buf: [u8; 256],
    prev: Option<(u64, u64)>,
}

impl CpuStat {
    fn open() -> std::io::Result<Self> {
        Ok(CpuStat {
            file: File::open("/proc/stat")?,
            buf: [0; 256],
            prev: None,
        })
    }

    /// Busy percentage since the previous sample; `None` for the first one.
    fn sample(&mut self) -> Option<f64> {
        self.file.seek(SeekFrom::Start(0)).ok()?;
        let n = self.file.read(&mut self.buf).ok()?;
        let line = self.buf[..n].split(|&b| b == b'\n').next()?;
        let mut fields = std::str::from_utf8(line).ok()?.split_ascii_whitespace();
        if fields.next()? != "cpu" {
            return None;
        }

        // user nice system idle iowait irq softirq steal (guest time is already in user)
        let (mut total, mut idle) = (0u64, 0u64);
        for (i, field) in fields.take(8).enumerate() {
            let ticks: u64 = field.parse().ok()?;
            total += ticks;
            if i == 3 || i == 4 {
                idle += ticks;
            }
        }

        let (prev_total, prev_idle) = self.prev.replace((total, idle))?;
        let dt = total.saturating_sub(prev_total);
        if dt == 0 {
            return Some(0.0);
        }
        let di = idle.saturating_sub(prev_idle).min(dt);
        Some(100.0 * (dt - di) as f64 / dt as f64)
    }

    fn reset(&mut self) {
        self.prev = None;
    }
}

/// `online` files of external power supplies (AC adapters and USB-C sources).
fn find_power_sources() -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir("/sys/class/power_supply") else { return Vec::new() };
    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            fs::read_to_string(p.join("type"))
                .is_ok_and(|t| matches!(t.trim(), "Mains" | "USB"))
        })
        .map(|p| p.join("online"))
        .collect()
}

/// Machines without any external supply entries (desktops) always count as on AC.
fn on_ac(sources: &[PathBuf]) -> bool {
    sources.is_empty()
        || sources
            .iter()
            .any(|p| fs::read_to_string(p).is_ok_and(|s| s.trim() == "1"))
}

fn get_profile() -> Option<String> {
    let out = Command::new("busctl")
        .args(["--system", "get-property"])
        .args(PPD)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    // Output looks like: s "balanced"
    let text = String::from_utf8(out.stdout).ok()?;
    Some(text.trim().strip_prefix("s ")?.trim_matches('"').to_string())
}

fn set_profile(profile: &str) -> bool {
    Command::new("busctl")
        .args(["--system", "set-property"])
        .args(PPD)
        .args(["s", profile])
        .status()
        .is_ok_and(|s| s.success())
}

#[derive(Debug)]
enum Mode {
    /// Waiting for a load spike.
    Normal,
    /// In a load spike, waiting for the machine to go idle. `restore` is the
    /// profile to drop to afterwards, or `None` when the spike was left alone
    /// (the active profile was not one to boost from), so nothing is switched
    /// back when it ends.
    Loaded { restore: Option<String> },
}

/// A profile that is already `performance` at startup is most likely a boost
/// left behind by an earlier run, so it is dropped after the next idle period.
fn initial_mode(c: &Config) -> Mode {
    match get_profile().as_deref() {
        Some("performance") => Mode::Loaded { restore: Some(c.drop_to.target("balanced")) },
        _ => Mode::Normal,
    }
}

/// Switch to performance if the active profile is one to boost from. Returns
/// the profile to drop back to once the load is gone.
fn boost(c: &Config) -> Option<String> {
    let Some(profile) = get_profile() else {
        eprintln!("load spike: could not read the active profile");
        return None;
    };
    if !c.boost_from.includes(&profile) {
        eprintln!("load spike: leaving {profile} alone");
        return None;
    }
    if !set_profile("performance") {
        eprintln!("load spike: failed to set performance");
        return None;
    }
    eprintln!("load spike: {profile} -> performance");
    Some(c.drop_to.target(&profile))
}

/// Drop back to `target`, unless the profile was changed by someone else
/// while boosted.
fn relax(target: &str) {
    match get_profile().as_deref() {
        Some("performance") => {
            if set_profile(target) {
                eprintln!("idle: performance -> {target}");
            } else {
                eprintln!("idle: failed to set {target}");
            }
        }
        Some(other) => eprintln!("idle: profile is now {other}, leaving it"),
        None => eprintln!("idle: could not read the active profile"),
    }
}

fn main() {
    let args = parse_args();
    let mut cpu = CpuStat::open().unwrap_or_else(|e| {
        eprintln!("autoperf: cannot open /proc/stat: {e}");
        exit(1)
    });
    let sources = find_power_sources();
    let mut config_file = ConfigFile { path: args.config, seen: None };
    let mut state = StateFile::new();

    let mut c = Config::default();
    let mut mode = Mode::Normal;
    let mut started = false;
    let mut paused = false;
    let mut last_ac = on_ac(&sources);
    let mut hot = 0u32;
    let mut quiet = 0u64;

    loop {
        if let Some(next) = config_file.poll() {
            eprintln!("settings: {}", next.describe());
            c = next;
            hot = 0;
            quiet = 0;
            if !started {
                started = true;
                mode = initial_mode(&c);
            }
        }

        // Omarchy applies the saved profile for the new power source itself,
        // which ends any boost.
        let ac = on_ac(&sources);
        if ac != last_ac {
            eprintln!("power source: {}", if ac { "AC" } else { "battery" });
            last_ac = ac;
            mode = Mode::Normal;
            cpu.reset();
            hot = 0;
            quiet = 0;
        }

        if c.ac_only && !ac {
            if !paused {
                eprintln!("on battery: paused");
                paused = true;
                // Only still boosted if ac_only was just switched on.
                if let Mode::Loaded { restore: Some(to) } = &mode {
                    relax(to);
                }
                mode = Mode::Normal;
            }
            state.publish(&mode, paused);
            sleep(BATTERY_POLL);
            continue;
        }
        if paused {
            eprintln!("watching CPU load");
            paused = false;
            cpu.reset();
            hot = 0;
            quiet = 0;
        }

        if let Some(busy) = cpu.sample() {
            if args.verbose {
                eprintln!("cpu {busy:.1}%");
            }
            match &mode {
                Mode::Normal => {
                    hot = if busy >= c.up { hot + 1 } else { 0 };
                    if hot >= c.up_samples {
                        hot = 0;
                        quiet = 0;
                        mode = Mode::Loaded { restore: boost(&c) };
                    }
                }
                Mode::Loaded { restore } => {
                    quiet = if busy <= c.idle { quiet + 1 } else { 0 };
                    if quiet >= c.idle_secs.div_ceil(c.interval).max(1) {
                        quiet = 0;
                        if let Some(to) = restore {
                            relax(to);
                        }
                        mode = Mode::Normal;
                    }
                }
            }
        }

        state.publish(&mode, paused);
        sleep(Duration::from_secs(c.interval));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_file_gives_defaults() {
        assert_eq!(Config::parse(""), Config::default());
    }

    #[test]
    fn parses_every_key() {
        let c = Config::parse(
            "# comment\nboost_from=both\nup = 75\nup_samples=3\nidle=5\nidle_secs=20\n\
             drop_to=power-saver\nac_only=false\ninterval=2\n",
        );
        assert_eq!(
            c,
            Config {
                boost_from: BoostFrom::Both,
                up: 75.0,
                up_samples: 3,
                idle: 5.0,
                idle_secs: 20,
                drop_to: DropTo::PowerSaver,
                ac_only: false,
                interval: 2,
            }
        );
    }

    #[test]
    fn bad_values_fall_back() {
        let c = Config::parse("up=150\nboost_from=turbo\nup_samples=0\nbogus\n");
        assert_eq!(c.up, 60.0);
        assert_eq!(c.boost_from, BoostFrom::Balanced);
        assert_eq!(c.up_samples, 1);
    }

    #[test]
    fn idle_must_stay_below_up() {
        assert_eq!(Config::parse("up=50\nidle=50").idle, 10.0);
        assert_eq!(Config::parse("up=5\nidle=8").idle, 0.0);
    }

    #[test]
    fn boost_from_and_drop_to() {
        assert!(BoostFrom::Both.includes("power-saver"));
        assert!(!BoostFrom::Balanced.includes("power-saver"));
        assert!(!BoostFrom::Both.includes("performance"));
        assert_eq!(DropTo::Previous.target("power-saver"), "power-saver");
        assert_eq!(DropTo::Balanced.target("power-saver"), "balanced");
    }
}
