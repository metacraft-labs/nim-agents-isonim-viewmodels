## The progress pie: one indicator that shows an item's state by its colour
## and its progress by a wedge of the same colour, for every front end of
## this library (a session, an initiative, a fleet row; their tabs, lines and
## menus).
##
## This module is renderer-neutral. It says WHAT a pie shows -- its role (the
## colour family), the share done, whether that share is known at all, and
## the words that name it -- and never how it is drawn: each front end draws
## a `ProgressPie` with its own inks and shapes. So every front end shows the
## same role, the same fraction and the same accessible name for the same
## item.
##
## - **The role** (`PieRole`) folds the item's state onto a few colour
##   families: needs input is a warning, running (an initiative: working) a
##   success, queued an information, failed (an initiative: blocked) an
##   error; idle and ended keep roles of their own, because a front end draws
##   idle hollow and ended grey.
## - **The progress** is done of total: a session's latest plan in steps
##   (`FleetSession.planDone` / `planTotal`), an initiative's milestones
##   completed of planned (`MilestoneSummary`). A total of 0 is UNKNOWN
##   progress (`known` false): a front end must never draw it as "0 %" or as
##   done. A done count below 0 counts as 0, one above the total as the total.
## - **The words** (`label`) are built here, once: the state word, then
##   `<done> of <total> <unit>, <percent>%` when the progress is known
##   (`needs input, 3 of 19 milestones, 16%`), else `progress unknown`
##   (`running, progress unknown`), so a reader never takes an unknown share
##   for 0 %. The percentage is rounded half
##   up, the rule the server's milestone summary uses
##   (`nim_agents/agent_harbor/initiatives.summarize`).
##
## Signal-free and app-agnostic; identical on the C and JS targets.

import nim_agents/agent_harbor/[session_directory, fleet_records, initiatives]

export session_directory, fleet_records, initiatives

type
  PieRole* = enum
    ## The colour family a pie is drawn in.
    prWarning = "warning" ## needs input
    prSuccess = "success" ## running, working
    prInfo = "info"       ## queued
    prError = "error"     ## failed, blocked
    prIdle = "idle"       ## idle: drawn hollow
    prEnded = "ended"     ## ended, done: drawn grey

  ProgressUnit* = enum
    ## What a pie's progress counts, as its words name it.
    puSteps = "steps"           ## a session's plan
    puMilestones = "milestones" ## an initiative's plan

  ProgressPie* = object
    ## What one pie shows.
    role*: PieRole
    fraction*: float
      ## The share done, 0 to 1; 0 when the progress is not known.
    known*: bool
      ## The progress is known (a total above 0). An unknown pie draws no
      ## wedge, and reads as neither "0 %" nor done.
    done*, total*: int
      ## The counts the fraction was taken from, `done` kept between 0 and
      ## `total`; both 0 when the progress is not known.
    percent*: int
      ## The share as the words say it, rounded half up; 0 when not known.
    label*: string
      ## The pie's accessible name: the state word, then the progress, or
      ## `progress unknown`.

# ---------------------------------------------------------------------------
# State words: the one wording of each state, which every view of it uses
# ---------------------------------------------------------------------------

proc attentionWord*(attention: SessionAttention): string =
  ## A session's state word.
  case attention
  of saNeedsInput: "needs input"
  of saIdle: "idle"
  of saRunning: "running"
  of saQueued: "queued"
  of saFailed: "failed"
  of saEnded: "ended"

proc stateWord*(state: InitiativeState): string =
  ## An initiative's state word.
  case state
  of isNeedsInput: "needs input"
  of isBlocked: "blocked"
  of isWorking: "working"
  of isIdle: "idle"
  of isEnded: "ended"

proc categoryWord*(category: FleetCategory): string =
  ## A fleet row's state word.
  case category
  of fcNeedsInput: "needs input"
  of fcRunning: "running"
  of fcQueued: "queued"
  of fcFailed: "failed"
  of fcEnded: "ended"

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------

proc pieRoleOf*(attention: SessionAttention): PieRole =
  case attention
  of saNeedsInput: prWarning
  of saRunning: prSuccess
  of saQueued: prInfo
  of saFailed: prError
  of saIdle: prIdle
  of saEnded: prEnded

proc pieRoleOf*(state: InitiativeState): PieRole =
  case state
  of isNeedsInput: prWarning
  of isWorking: prSuccess
  of isBlocked: prError
  of isIdle: prIdle
  of isEnded: prEnded

proc pieRoleOf*(category: FleetCategory): PieRole =
  case category
  of fcNeedsInput: prWarning
  of fcRunning: prSuccess
  of fcQueued: prInfo
  of fcFailed: prError
  of fcEnded: prEnded

# ---------------------------------------------------------------------------
# The pie
# ---------------------------------------------------------------------------

const ProgressUnknownWords* = "progress unknown"
  ## What a pie with no known progress says after its state word.

proc unitWord(unit: ProgressUnit; total: int): string =
  ## `steps` / `milestones`, singular for a total of one.
  case unit
  of puSteps: (if total == 1: "step" else: "steps")
  of puMilestones: (if total == 1: "milestone" else: "milestones")

proc halfUpPercent*(done, total: int): int =
  ## `done` of `total` as a whole percentage, rounded half up (the server's
  ## milestone-summary rule); 0 for a total of 0.
  if total <= 0: 0 else: (done * 200 + total) div (2 * total)

proc pieLabel*(word: string; pie: ProgressPie; unit: ProgressUnit): string =
  ## The accessible name: `<state word>, <done> of <total> <unit>,
  ## <percent>%` when the progress is known, else `<state word>, progress
  ## unknown`.
  if not pie.known: word & ", " & ProgressUnknownWords
  else: word & ", " & $pie.done & " of " & $pie.total & " " &
    unitWord(unit, pie.total) & ", " & $pie.percent & "%"

proc progressPie*(role: PieRole; word: string; done, total: int;
                  unit: ProgressUnit): ProgressPie =
  ## The pie of an item in `role`, named `word`, `done` of `total` `unit`.
  ## The one constructor every `pieOf` goes through, so the progress edges
  ## (no total, a negative count, a count above the total) are decided once.
  result = ProgressPie(role: role)
  if total > 0:
    let d = max(0, min(done, total))
    result.known = true
    result.done = d
    result.total = total
    result.fraction = d.float / total.float
    result.percent = halfUpPercent(d, total)
  result.label = pieLabel(word, result, unit)

proc pieOf*(attention: SessionAttention; done, total: int): ProgressPie =
  ## A session's pie: its state and its plan's steps.
  progressPie(pieRoleOf(attention), attentionWord(attention), done, total, puSteps)

proc pieOf*(state: InitiativeState; summary: MilestoneSummary): ProgressPie =
  ## An initiative's pie: its state and its milestones, completed of planned.
  progressPie(pieRoleOf(state), stateWord(state), summary.completedMilestones,
              summary.totalMilestones, puMilestones)

proc pieOf*(category: FleetCategory; done, total: int): ProgressPie =
  ## A fleet row's pie: its category and its session's plan steps.
  progressPie(pieRoleOf(category), categoryWord(category), done, total, puSteps)

proc pieOf*(session: FleetSession; attention: SessionAttention): ProgressPie =
  ## A session's pie from the session itself (`planDone` of `planTotal`).
  pieOf(attention, session.planDone, session.planTotal)
