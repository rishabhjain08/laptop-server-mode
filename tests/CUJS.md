# Customer journeys and how each is tested

Every journey a laptop owner can take, with its variations. "Auto" = covered
by `tests/run.sh` (every combination, mocked power and services). "Live" = run
on a real laptop with scripts. "You" = needs a person (a physical action or
looking at the screen).

## A. Install and lifecycle

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| A1 | Fresh install | with / without admin rights; server mode starts OFF | Live |
| A2 | Update in place (re-run `install.sh`) | config, state and plugins kept; no duplicate processes; Penguin and services stay up | Live |
| A3 | Update from the old `services/` layout | services moved to `plugins/` | Live |
| A4 | Uninstall | server mode on / off; tasks, processes, temp plan, shortcut and app id removed; services stopped; normal plan active | Live |
| A5 | Claude add-on install / re-run / uninstall | box exists / not; `--remove-box` | Live (re-run), You (fresh box) |
| A6 | Plugins: add, update, list, remove | bad folder, unknown name, running service | Live |

## B. Turning server mode on and off

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| B1 | Toggle | from off / on / paused; plugged in / battery above limit / at or below limit | Auto (rule), Live (power plan) |
| B2 | Low-battery prompt when turning on | plug in while waiting / turn on anyway / cancel / Esc | Live (dialog driven by script), You (look) |
| B3 | Ways to toggle | tray left-click / flyout card / flyout switch / keyboard | Live (flyout driven by script), You (real clicks) |

## C. Battery

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| C1 | Unplug while on | above limit: stays on; reaches limit: pauses, toast | Auto, Live (limit raised), You (real unplug) |
| C2 | Plug in while paused | resumes, toast | Auto, Live, You |
| C3 | "Turn on anyway", then plug in and unplug again | override cleared by plugging in | Auto, Live |
| C4 | Boot on battery below the limit | starts paused | Auto |

## D. Lid and sleep

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| D1 | Close the lid | on: stays up (AC, battery); off or paused: sleeps normally | Live (on), You (off) |
| D2 | Watchdog dies with the lid closed | keep-awake keeps the system up until it's back | Live |

## E. Restarts

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| E1 | Restart | on / off; lid open / closed; AC / battery | Live |
| E2 | Shut down, then power on | | You |
| E3 | Hooks around a restart | shutdown hooks, boot hooks once | Live |

## F. Sessions and the tray

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| F1 | Before anyone signs in | server mode and services run, no tray | Live |
| F2 | Sign in / lock / sign out | tray appears; services keep running | You |
| F3 | Quit the tray, get it back | Start menu shortcut | Live, You |
| F4 | Tray crashes | | Live |

## G. Services from the flyout

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| G1 | Switch a service on / off | server mode on / off; stop-with-server-mode | Auto, Live |
| G2 | Status shown | running / starting / stopping / off / needs sign-in / not responding / waits for server mode | Auto (states), Live (preview) |
| G3 | Stop all services | box distro shut down; switches turn on again | Live |
| G4 | Failing service | backoff, service-failed hook once | Auto, Live |

## H. Flyout

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| H1 | Open / close | right-click again, Esc, click outside | Live (script), You |
| H2 | Buttons | screen off, open logs, stop all, quit, restart background checks | Live (script), You |
| H3 | Keyboard | Tab, arrows, Enter, Space, Esc | Live (script) |
| H4 | Look | light / dark, accent color, DPI, many services | Live (rendered previews), You |

## I. Remote access (Claude add-on)

| ID | Journey | Variations | How |
| --- | --- | --- | --- |
| I1 | Remote Control after a restart | connects first try / gives up and is reconnected | Live |
| I2 | Network drops and comes back | Wi-Fi off / on | Live |
| I3 | ClaudeBox isolation | after every restart | Live |

## K. Things going wrong

| ID | Journey | How |
| --- | --- | --- |
| K1 | state.json corrupt or missing | Live |
| K2 | config.json invalid | Live |
| K3 | You switch power plans while server mode is on | Live |
| K4 | The temporary plan is deleted from outside | Live |
| K5 | A WSL distro is shut down | Live |
| K6 | Logs grow past 1 MB | Live |
| K7 | Watchdog / keep-awake / tray process killed | Live |

## Results, 11 October 2026

Automated: `tests/run.sh` passes (Logic 1,284 checks, Tray 44 checks); planted
bugs were caught by both suites. Live runs were on the author's laptop with
the lid closed.

| Result | Journeys |
| --- | --- |
| Pass | A1, A2, A3, A4, A6, A7 (re-run); B1, B2 (answers), B3 (scripted input); C1–C4 (rule, limit raised live); D1 (on), D2; E1 (on: lid closed, AC and battery), E3; F1; G1–G4; H1–H3 (scripted), H4 (previews); I1, I3; K1–K7 |
| Fixed on the way | K1 damaged state.json turned server mode off; K2 invalid config.json errored every round; D2 nothing held the system awake while the watchdog was down; F3 no way back after "Quit tray"; I1 Remote Control gave up after a restart; A1 needed admin rights; K7 a crashed watchdog wasn't restarted and leaked WSL processes |
| Needs a person | A5 creating ClaudeBox from scratch (skipped: it would wipe the box and its sign-in) |

### With a person at the laptop (same day)

Real mouse and keyboard input was sent to the signed-in desktop by a script
(screenshots checked); the person did only the physical steps.

| Result | Journeys |
| --- | --- |
| Pass | B2 dialog on screen: Cancel, "Turn on anyway", and plugging in while it waits; B3 real clicks on the icon, the card and the switches; C1 pause on battery (limit raised), C2 plugging in resumes; D1 off + lid closed sleeps (WSL clock lost the 3m25s); E2 power off, power button, not signed in: both Claude sessions answered from the phone; F2 signed out: both answered from the phone, and the tray came back at sign-in; F3 Start menu shortcut; F4 tray crash restarted by the watchdog, not after Quit; H1–H3 open, close, keyboard, logs, quit, screen off (the screen went dark); H4 the flyout, the paused state and the dialog at 250% scale; notification pop-ups |
| Fixed on the way | Notifications showed "LaptopServerMode" with no icon after a reinstall (now a fresh app id per install); the Remote Control check broke on a transcript with a NUL byte (grep -a); a crashed tray stayed gone until the next sign-in |
