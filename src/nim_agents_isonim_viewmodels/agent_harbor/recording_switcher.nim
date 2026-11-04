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

  RecordingButtons* = object
    buttons*: seq[RecordingButton]
    hidden*: int        ## recordings beyond `maxShown`, behind a `+N`

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
                       maxShown = high(int)): RecordingButtons =
  ## The buttons in order. When more recordings exist than `maxShown`, the
  ## first `maxShown - 1` are drawn and the active one takes the last place
  ## (the session strip's rule), the rest counted in `hidden`.
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
                                       active: i == activeAt)
  result.hidden = entries.len - shown.len
