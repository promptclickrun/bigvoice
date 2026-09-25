# Design

<!-- impeccable:design-schema 1 -->

bigvoice implements the **bigvoice brand & interface system, V2 · 2026**
(source: [`design/brand-v2/brand-and-interface-v2.dc.html`](design/brand-v2/brand-and-interface-v2.dc.html)).
This file records the system as built in SwiftUI. Tokens live in
`Sources/Bigvoice/UI/Theme.swift`; the mark and icons in `Mark.swift`.

## Principles

- **Warm dark. One loud color.** Ink and paper carry the interface. Signal is
  reserved for sound and the one action that starts it: if something is orange,
  something is listening. The app is dark by design in every system appearance.
- **One shape, every state.** The sidebar mark, menu bar glyph, stage, and
  floating capsule all follow a single state.
- **Moves like speech.** Three curves, no bounce. Nothing loops unless sound is
  present: the bars are the microphone, never a screensaver. Idle is still.

## Color

sRGB conversions of the spec's oklch values.

| Token | oklch | sRGB | Role |
| --- | --- | --- | --- |
| Ink | .155 .006 60 | `#0E0C0A` | Canvas |
| Char | .20 .007 60 | `#181513` | Sidebar, capsule, cards |
| Surface | .235 .008 60 | `#211D1A` | Keys, raised fields |
| Stone | .72 .012 70 | `#AAA39D` | Secondary text |
| Paper | .965 .008 80 | `#F6F3EE` | Primary text |
| Signal | .76 .17 52 | `#FF8D39` | Listening states, primary action, delivered |
| Caution | .84 .13 88 | `#EEC55E` | Warnings only |

Hairlines are warm white, `rgba(255, 240, 220, α)`: .07 dividers, .08 card
borders, .1 keys and fields, .14 capsule, .16 outline buttons. Measured
contrast: paper on ink 17.6:1, stone on char 7.3:1, ink on signal 8.5:1.

## Type

| Role | Face | Use |
| --- | --- | --- |
| Display | Bricolage Grotesque (variable: wght 200–800, wdth 75–100, opsz 12–96) | Page titles 40 pt, wght 620, wdth 90, tracking −0.035 em; wordmark 23 pt, wght 700, wdth 88 |
| Interface | Geist (variable) | Section titles 17 pt 600; rows 13.5 pt 500; details 12.5 pt; body 15 pt |
| Data | Geist Mono (variable) | Shortcuts, timers, sizes, paths, status tags (11.5 pt 500, +0.05 em, uppercase) |

Fonts are bundled (SIL OFL 1.1), pinned by SHA-256 in `Resources/Fonts`, and
addressed through their variation axes. Modifier symbols (⌃ ⌥ ⇧ ⌘) in keycaps use
the system face because Geist Mono draws them undersized.

## Motion

| Curve | Timing | Use |
| --- | --- | --- |
| Swell | 560 ms · cubic-bezier(.2, .8, .2, 1) · 28 ms stagger | The mark; state changes; capsule width |
| Settle | 340 ms · cubic-bezier(.3, .7, .4, 1) | Pages (opacity + 14 pt rise), panels, toggles |
| Hush | 180 ms · cubic-bezier(.4, 0, 1, 1) | Cancel, dismiss, Esc |

Titles swap with opacity, a 10 pt blur, and a 10 pt rise; transcript words land
individually with a 6 pt blur and 8 pt rise, the newest word in Signal while
listening. Reduce Motion replaces movement with short fades and holds the mark
in its static profile. Live timelines run only while sound is present (marks at
30 fps, waveforms at 60 fps).

## The mark

Five rounded bars (bar .11, gap .085 of the mark size; dot .38).

| State | Shape |
| --- | --- |
| Idle | A closed dot: ready, not recording |
| Arming | Five points line up while the microphone opens |
| Listening | Bars follow the live level, profile .42 .7 1 .78 .5 |
| Transcribing | A travelling wave of dots |
| Inserting | The caret: words landing in your field |
| Delivered | A check (strokes pivot on their end caps), then back to quiet |

## Icons

Built from the mark's parts on a 24-unit grid with a 2-unit stroke; each has one
gesture on hover or when active: wave (Dictation), stack (Models), sliders
(Settings), mic, lock, download, key, check, close, rescan, stop.

## Components

- **Buttons.** Signal primary pill, 44 pt, ink text, press scale .97. Outline
  pills, 36/44 pt, .16 border, .06 hover fill. Signal text links. Catalog actions
  are fixed 96 × 34 and walk Install → Cancel → Use → In use.
- **Keycaps.** Geist Mono on Surface, radius 9, hard 3 pt drop; pressed keys drop
  2 pt and turn Signal. Small variant 30 × 28 for Settings.
- **Cards.** Char, radius 20 (stage 26), .08 border; the stage and active model
  take a Signal border while listening or active.
- **Toggle.** 40 × 24 track, 18 pt knob, Signal when on, Settle curve.
- **Select.** Surface field, radius 9, 32 pt, chevron.
- **Size bar.** Disk size drawn to scale (180 pt = largest model), install
  progress as Signal fill.
- **Capsule.** 62 pt, Char, .14 border, 0 14 40 shadow. Widths: arming 232,
  listening 372, working and delivered 262. A pill instruction sits above it.
- **Toasts.** Char, radius 16, bottom-center; info dismisses after 4.5 s.

## Layout

Window 1116 × 800 (minimum 900 × 660). Sidebar 236 pt Char with a sliding nav
highlight; content max width 880 with 48 pt side padding. Page order and copy
follow the spec, plus a setup section (model, microphone, Accessibility with
Repair) shown only until ready.
