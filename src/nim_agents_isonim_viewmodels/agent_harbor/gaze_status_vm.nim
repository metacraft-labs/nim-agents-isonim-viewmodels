## `GazeStatusVM`: the status line's gaze mark (CodeTracer
## Eye-Tracking-Context "Privacy and control"): while gaze is tracked a
## visible mark, `Gaze`; while paused, `Gaze paused`, drawn struck; when off,
## no mark at all. Its tooltip names the one key that pauses (and resumes)
## tracking, as the front-end's keymap binds it.
##
## The words and the toggle are nim-agents' (`instruction_composer`:
## `gazeMark`, `gazeMarkTooltip`, `toggledGaze`). This viewmodel publishes
## the state and keeps the key's name, which only the front-end knows.
##
## **One state for the window.** The composer's gaze chip says the same as
## the mark: a host passes `onChange`, which hears every state the mark
## takes (the pause key, or the provider turning tracking on or off), and
## sets the composer's gaze with it (`OmniboxComposerVM.setGaze`).
##
## The pause key never turns tracking on: tracking is opt-in, so off stays
## off until the operator enables it where gaze tracking is configured
## (`setState`, from the provider).

import isonim/core/signals
import isonim/viewmodel
import nim_agents/instruction_composer

export viewmodel, signals, instruction_composer

type
  GazeStatusVM* = ref object of ViewModel
    state*: Signal[GazeState]
    chord*: string
      ## The pause key as the keymap names it (`Ctrl+Alt+Y`).
    onChange*: proc(state: GazeState)
      ## Hears every state the mark takes; nil for none.

proc newGazeStatusVM*(state = gsOff; chord = "";
                      onChange: proc(state: GazeState) = nil): GazeStatusVM =
  withViewModel proc(dispose: proc()): GazeStatusVM =
    GazeStatusVM(state: createSignal(state), chord: chord, onChange: onChange)

proc shown*(vm: GazeStatusVM): bool =
  ## Tracked: the mark is drawn (tracking or paused).
  gazeMark(vm.state.val).shown

proc text*(vm: GazeStatusVM): string =
  ## Tracked: `Gaze`, `Gaze paused`, or "" when off.
  gazeMark(vm.state.val).text

proc struck*(vm: GazeStatusVM): bool =
  ## Tracked: the glyph is drawn struck through (paused).
  vm.state.val == gsPaused

proc tooltip*(vm: GazeStatusVM): string =
  ## Tracked: what the mark is, and the key that pauses or resumes it.
  gazeMarkTooltip(vm.state.val, vm.chord)

proc setState*(vm: GazeStatusVM; state: GazeState) =
  ## The provider's state: tracking turned on or off, or paused elsewhere.
  if vm.state.val == state: return
  vm.state.val = state
  if vm.onChange != nil: vm.onChange(state)

proc togglePause*(vm: GazeStatusVM): bool =
  ## The pause key: tracking pauses, paused resumes. Off stays off. True
  ## when the state changed.
  let next = toggledGaze(vm.state.val)
  if next == vm.state.val: return false
  vm.setState(next)
  true
