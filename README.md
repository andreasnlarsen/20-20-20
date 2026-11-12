# 20-20-20

A macOS menu-bar app that makes you take the 20-20-20 eye break: every 20 minutes, look at something 20 feet (6 m) away for 20 seconds.

During your work hours, every 20 minutes every display goes dark for 30 seconds: 10 seconds to get to a window, then the 20. There is no skip button, no snooze and no Quit. If you kill the app, macOS starts it again and the break starts over.

Free and open source under the [MIT licence](LICENSE). Requires macOS 14 or later.

## Install

With Homebrew:

```sh
brew install --cask andreasnlarsen/tap/20-20-20
```

Homebrew 6 and later ask you to trust taps outside the official catalogue. If the install is refused with "untrusted tap", run `brew trust andreasnlarsen/tap` once and install again.

Or download `20-20-20-<version>.zip` from [Releases](https://github.com/andreasnlarsen/20-20-20/releases), unzip it, move the app to `/Applications` and open it once. The app is signed with a Developer ID and notarized by Apple.

## First start

The Work hours window opens. Choose a start time, an end time and the days, then confirm. Until you confirm, every day 08:00–18:00 applies.

After that the app lives in the menu bar as an eye icon. A menu bar manager such as Bartender may hide new icons; set 20-20-20 to always show there.

## What to expect

- **Breaks cannot be skipped.** Nothing on screen ends a break early. Keyboard focus stays where it was, so a running dictation keeps going.
- **Calls get no special treatment.** People watching your shared screen will see the dark screen. Before a demo, use a pause.
- **Pause** for 30, 60 or 120 minutes from the menu. A pause starts and ends with a break, and you cannot pause again for 2 hours afterwards.
- **Work hours** can be changed from the menu. A change starts the next day.
- **Locking the Mac** or letting it sleep for 20 seconds or more counts as a break.

## Remove

```sh
brew uninstall --cask 20-20-20
```

If you installed it another way, run `./uninstall.sh` from this repository.

## Build from source

```sh
./build.sh          # build/20-20-20.app
./build.sh test     # test build with shortened times and a Quit item
./install.sh        # build, install to ~/Applications and start
```

[SPEC.md](SPEC.md) has the full requirements, the reasons behind them, and what has and has not been verified.
