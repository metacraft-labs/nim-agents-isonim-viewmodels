## The recording switcher's contract: numbered buttons `1 2 3 …` that select
## one of several recordings grouped for browsing together. One control for
## two uses: the replays loaded for an Agent Harbor initiative (a test's
## trace, a recording an agent made), and the processes of a multi-process
## recording (where correlation markers also move between them). Either way
## the recordings may come from different sources, revisions or builds.
##
## Signal-free and front-end neutral: `recordingButtons` turns the host's
## recordings into the buttons every renderer draws (a web button row, a TUI
## run of `[1] 2 3`, GPUI chips), and how many fit is the caller's number.

import std/strutils

type
  RecordingState* = enum
    rsReady = "ready"
    rsLoading = "loading"
    rsFailed = "failed"     ## it is there, but loading it failed
    rsMissing = "missing"   ## it is not there any more (deleted, expired)

  RecordingEntry* = object
    ## One recording of the group.
    id*: string
    name*: string       ## the recording (`calc test trace`, a process role)
    revision*: string   ## the source revision it was recorded at
    origin*: string     ## where it came from (`ct test run`, `agent session …`)
    state*: RecordingState
    error*: string      ## why it failed to load, or where it went

  RecordingButton* = object
    number*: int        ## 1-based, as drawn
    id*: string
    tooltip*: string
    state*: RecordingState
    active*: bool
    ringed*: bool
      ## A correlation marker leads to this recording (a multi-process
      ## recording's process): drawn with a quiet ring until the reader
      ## follows it. Never the active one.

  RecordingButtons* = object
    buttons*: seq[RecordingButton]
    hidden*: int        ## recordings beyond `maxShown`, behind a `+N`
    hiddenStates*: seq[RecordingState]
      ## The states of the hidden recordings, in order: the `+N` takes the
      ## most severe of them.
    hiddenRinged*: bool
      ## The ringed recording is behind `+N`: the chip carries the ring.

proc tooltipOf*(entry: RecordingEntry): string =
  ## `calc test trace · revision 41d7f96 · from ct test run`, and the state
  ## when it is not ready.
  var parts = @[entry.name]
  if entry.revision.len > 0: parts.add "revision " & entry.revision
  if entry.origin.len > 0: parts.add "from " & entry.origin
  result = parts.join(" \xC2\xB7 ")
  case entry.state
  of rsReady: discard
  of rsLoading: result.add " (loading)"
  of rsFailed:
    result.add " (failed to load" & (if entry.error.len > 0: ": " & entry.error else: "") & ")"
  of rsMissing:
    result.add " (missing" & (if entry.error.len > 0: ": " & entry.error else: "") & ")"

proc recordingButtons*(entries: openArray[RecordingEntry]; activeId: string;
                       maxShown = high(int); ringedId = ""): RecordingButtons =
  ## The buttons in order. When more recordings exist than `maxShown`, the
  ## first `maxShown - 1` are drawn and the active one takes the last place
  ## (the session strip's rule), the rest counted in `hidden`. `ringedId`
  ## names the recording a correlation marker leads to (none by default; a
  ## ring on the active recording is ignored): its button is `ringed`, or,
  ## when it is hidden, the chip (`hiddenRinged`).
  if entries.len == 0: return
  var activeAt = -1
  for i, e in entries:
    if e.id == activeId: activeAt = i
  var shown: seq[int]
  if entries.len <= maxShown or maxShown <= 0:
    for i in 0 ..< entries.len: shown.add i
  else:
    for i in 0 ..< maxShown - 1: shown.add i
    shown.add(if activeAt >= maxShown - 1: activeAt else: maxShown - 1)
  for i in shown:
    result.buttons.add RecordingButton(number: i + 1, id: entries[i].id,
                                       tooltip: tooltipOf(entries[i]),
                                       state: entries[i].state,
                                       active: i == activeAt,
                                       ringed: ringedId.len > 0 and i != activeAt and
                                               entries[i].id == ringedId)
  result.hidden = entries.len - shown.len
  for i, e in entries:
    if i notin shown:
      result.hiddenStates.add e.state
      if ringedId.len > 0 and e.id == ringedId and i != activeAt:
        result.hiddenRinged = true

proc applyRecording*(entries: var seq[RecordingEntry]; entry: RecordingEntry): bool =
  ## One recording appeared or changed (a recording loading turned ready or
  ## failed): an entry whose id the group holds replaces it in place, any
  ## other is added at the end, so the buttons keep their numbers. True when
  ## the group changed; an entry without an id, or one equal to the held
  ## one, changes nothing.
  if entry.id.len == 0: return false
  for e in entries.mitems:
    if e.id == entry.id:
      if e == entry: return false
      e = entry
      return true
  entries.add entry
  true
