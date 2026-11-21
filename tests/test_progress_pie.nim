## The progress pie (`agent_harbor/progress_pie.nim`): the role each state
## folds onto, the progress edges, the accessible name's words, and the
## `pie` field every row and tab of the sessions family carries.
##
## No mocks: the rows are built by the production viewmodels over the
## fixture source and the invented working set (`newWorkingSetDataSource`),
## and each row's pie is checked against the row's own state and the
## progress its session or initiative reports. The expected words and
## fractions are written out by hand.

import std/[math, unittest]
import isonim/core/owner
import nim_agents_isonim_viewmodels

suite "the role":
  test "every state folds onto its colour family":
    check pieRoleOf(saNeedsInput) == prWarning
    check pieRoleOf(saRunning) == prSuccess
    check pieRoleOf(saQueued) == prInfo
    check pieRoleOf(saFailed) == prError
    check pieRoleOf(saIdle) == prIdle
    check pieRoleOf(saEnded) == prEnded
    check pieRoleOf(isNeedsInput) == prWarning
    check pieRoleOf(isWorking) == prSuccess
    check pieRoleOf(isBlocked) == prError
    check pieRoleOf(isIdle) == prIdle
    check pieRoleOf(isEnded) == prEnded
    check pieRoleOf(fcNeedsInput) == prWarning
    check pieRoleOf(fcRunning) == prSuccess
    check pieRoleOf(fcQueued) == prInfo
    check pieRoleOf(fcFailed) == prError
    check pieRoleOf(fcEnded) == prEnded

  test "every pie of a state has that state's role, whatever its progress":
    for a in SessionAttention:
      for (done, total) in [(0, 0), (0, 4), (2, 4), (4, 4), (9, 4)]:
        check pieOf(a, done, total).role == pieRoleOf(a)
    for s in InitiativeState:
      check pieOf(s, MilestoneSummary(completedMilestones: 1, totalMilestones: 2)).role ==
        pieRoleOf(s)
    for c in FleetCategory:
      check pieOf(c, 1, 3).role == pieRoleOf(c)

suite "the progress edges":
  test "0 of 0 is unknown: no wedge, and neither 0 % nor done":
    let p = pieOf(saRunning, 0, 0)
    check not p.known
    check p.fraction == 0.0
    check p.percent == 0
    check (p.done, p.total) == (0, 0)
    check p.label == "running, progress unknown"
    # A done count with no total is still unknown.
    check not pieOf(saRunning, 3, 0).known
    check not pieOf(isWorking, MilestoneSummary()).known

  test "0 of n is known and empty":
    let p = pieOf(saNeedsInput, 0, 5)
    check p.known
    check p.fraction == 0.0
    check p.label == "needs input, 0 of 5 steps, 0%"

  test "n of n is whole":
    let p = pieOf(saEnded, 7, 7)
    check p.known
    check p.fraction == 1.0
    check p.percent == 100
    check p.label == "ended, 7 of 7 steps, 100%"

  test "a done count above the total counts as the total; below 0 as 0":
    let over = pieOf(saRunning, 12, 7)
    check over.fraction == 1.0
    check (over.done, over.total) == (7, 7)
    check over.label == "running, 7 of 7 steps, 100%"
    let under = pieOf(saRunning, -2, 7)
    check under.fraction == 0.0
    check under.label == "running, 0 of 7 steps, 0%"

  test "the fraction is done of total":
    check almostEqual(pieOf(saRunning, 3, 19).fraction, 3.0 / 19.0)
    check almostEqual(pieOf(saRunning, 1, 4).fraction, 0.25)

suite "the accessible name's words":
  test "an initiative counts milestones, a session and a fleet row steps":
    check pieOf(isNeedsInput, MilestoneSummary(completedMilestones: 3,
                                               totalMilestones: 19)).label ==
      "needs input, 3 of 19 milestones, 16%"
    check pieOf(saFailed, 2, 5).label == "failed, 2 of 5 steps, 40%"
    check pieOf(fcQueued, 0, 3).label == "queued, 0 of 3 steps, 0%"
    check pieOf(isBlocked, MilestoneSummary(completedMilestones: 4,
                                            totalMilestones: 6)).label ==
      "blocked, 4 of 6 milestones, 67%"

  test "one of one is singular":
    check pieOf(saRunning, 0, 1).label == "running, 0 of 1 step, 0%"
    check pieOf(isWorking, MilestoneSummary(completedMilestones: 1,
                                            totalMilestones: 1)).label ==
      "working, 1 of 1 milestone, 100%"

  test "the percentage is rounded half up, as the server's summary":
    check pieOf(saRunning, 1, 8).percent == 13     # 12.5
    check pieOf(saRunning, 1, 3).percent == 33     # 33.3
    check pieOf(saRunning, 2, 3).percent == 67     # 66.7
    check pieOf(saRunning, 1, 200).percent == 1    # 0.5
    check halfUpPercent(3, 19) == 16

  test "with no progress the words are the state word and 'progress unknown'":
    for a in SessionAttention:
      check pieOf(a, 0, 0).label == attentionWord(a) & ", progress unknown"
    for s in InitiativeState:
      check pieOf(s, MilestoneSummary()).label == stateWord(s) & ", progress unknown"
    for c in FleetCategory:
      check pieOf(c, 0, 0).label == categoryWord(c) & ", progress unknown"
    # Never the words of 0 %.
    check pieOf(saRunning, 0, 0).label != pieOf(saRunning, 0, 5).label

  test "the state words":
    check attentionWord(saNeedsInput) == "needs input"
    check stateWord(isWorking) == "working"
    check stateWord(isBlocked) == "blocked"
    check categoryWord(fcEnded) == "ended"

suite "the pie fields":
  proc fleetSession(id: string; done, total: int): FleetSession =
    FleetSession(id: id, status: fsRunning, rawStatus: "running",
                 planDone: done, planTotal: total)

  test "a session item's pie is its state and its plan":
    let policy = tabStripSessionPolicy()
    let item = sessionItemOf(fleetSession("s1", 2, 5), 0, policy)
    check item.pie.role == pieRoleOf(item.attention)
    check item.pie.label == "running, 2 of 5 steps, 40%"
    check not sessionItemOf(fleetSession("s2", 0, 0), 0, policy).pie.known

  test "every row and tab carries the pie of its own state and progress":
    createRoot proc(disposeRoot: proc()) =
      let source = newWorkingSetDataSource()
      let initiatives = newInitiativesVM(source)
      initiatives.load()
      let rows = initiatives.rows
      check rows.len > 0
      for row in rows:
        check row.pie.role == pieRoleOf(row.state)
        check row.pie.known
        check row.pie.percent == row.progressPercent
        for item in row.sessions:
          check item.pie.role == pieRoleOf(item.attention)
      let tabs = newInitiativeTabStripVM(source)
      tabs.load()
      var initiativeTabs = 0
      for tab in tabs.tabs:
        case tab.kind
        of stkInitiative:
          inc initiativeTabs
          check tab.pie.role == pieRoleOf(tab.state)
          check tab.pie.known
          check tab.pie.label.len > stateWord(tab.state).len
        of stkSession:
          check tab.pie == tab.session.pie
      check initiativeTabs > 0
      let strip = newSessionTabStripVM(source, tsmSidebar)
      strip.load()
      for group in strip.groups:
        check group.pie.role == pieRoleOf(group.state)
        check group.pie.known == (group.progressText.len > 0)
        for item in group.tabs: check item.pie.role == pieRoleOf(item.attention)
      let fleet = newFleetSnapshotVM(newFixtureDataSource())
      fleet.load()
      check fleet.rows.len > 0
      for row in fleet.rows:
        check row.pie.role == pieRoleOf(row.category)
      initiatives.dispose()
      tabs.dispose()
      strip.dispose()
      fleet.dispose()
      disposeRoot()
