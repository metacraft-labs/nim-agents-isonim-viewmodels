## `ChangesVM`: one change in four tabs, in the order a reviewer reads it --
## a REVIEW TABS pattern: Spec Changes, Tests, Implementation Details and
## Code, under one panel titled `Changes`.
##
## The domain is nim-agents' `review_record` (the plan's review record, the
## approval grammar, the tiers, the tabs and their order) and `change_diff`
## (the change's files, their origins, key files first, filters). This
## viewmodel publishes them for one task's plan and one session's diff:
##
## - **what the data puts in** -- the load state, the error, the review
##   record and its open approval requests, the diff's file list, each
##   file's loaded hunks -- is cleared on `restart`;
## - **what the reader sets** -- the active tab (set once, on the first
##   load, to the first tab with content, then the reader's), the milestone
##   in scope, the open cards and which of them shows its diff, the Code
##   tab's filter, search, base and selected file, the open Request Changes
##   input and its text -- is kept on `restart` where it still exists.
##
## **Loading.** `load` asks for the record (`loadReviewRecord`) and the
## diff's file list (`loadChangeDiff`) together, then the hunks of the
## changed spec and governance files (`loadFileDiff`), which tiers 1 and 2
## are read from; it is ready when all have answered. A failed record read is the
## panel's error; a failed diff read leaves the record readable and the Code
## tab saying `No diff data`. A task with no plan (`TaskReview.hasPlan`
## false, or a record the source does not hold) shows only Spec Changes,
## read from the diff, and Code. A file's hunks load when the reader opens
## it (`loadFile`), each file with its own state.
##
## **Actions.** The reader's (`selectTab`, `selectMilestone`, `toggleCard`,
## `toggleDiff`, `setFilter`, `setQuery`, `selectBase`, `selectFile`,
## `stepFile`, `openInEditor`) move only this viewmodel; `openInEditor`
## publishes the path a host opens as a unified-diff editor tab. The writes
## (`approve`, `submitRequestChanges`, `revert`, `applyStaged`,
## `discardStaged`) go through the shared `ActionTracker` to the source's
## `submitAction`; a confirmed one reloads the record, as a server's change
## reaches a reader. Narrow tab labels come from the domain (`tabLabel`), so
## every host shortens them alike; widths stay in the hosts.

import std/[sets, strutils]
import isonim/core/[signals, owner]
import isonim/viewmodel
import nim_agents/agent_harbor/operator_actions
import ./data_source
import ./action_tracker

export data_source, action_tracker, viewmodel, signals

const
  ChangesPanelTitle* = "Changes"
  ChangesLoadingNotice* = "Loading changes\xE2\x80\xA6"
  ChangesErrorTitle* = "Could not load the changes"
  ApprovalNotRecordedText* = "approval not recorded"

type
  FileDiffState* = enum
    fdNotLoaded = "not-loaded"
    fdLoading = "loading"
    fdLoaded = "loaded"
    fdBinary = "binary"
    fdFailed = "failed"

  ChangesTabView* = object
    tab*: ReviewTab
    label*: string
    compactLabel*: string
    count*: int
    empty*: bool
    active*: bool

  SpecCardView* = object
    key*: string          ## what `toggleCard` and the actions name
    tier*: SpecTier
    title*: string        ## a requirement's heading, or a file's path
    path*: string
    stateText*: string    ## the state word: `pending`, `approved … `, `staged`, …
    stateRole*: string    ## `warning`, `success`, `quiet`, `error`
    summary*: string
    sections*: seq[string]
    commits*: seq[string]
    origin*: string       ## tier 1: `operator-distilled`, `branch-commit`, ""
    staged*: bool
    canApprove*: bool     ## pending, with a feedback request open for it
    open*: bool
    showsDiff*: bool
    requestOpen*: bool    ## the Request Changes input is open under it
    action*: ActionStatus ## the state of its last action
    actionReason*: string

  FileRow* = object
    file*: ChangedFile
    key*: bool            ## one of the plan's key source files
    counts*: string       ## `+a −r`
    selected*: bool

  FileDiffView* = object
    state*: FileDiffState
    file*: ChangedFile
    error*: string

  DetailsView* = object
    milestoneId*, title*: string
    notes*: string
    keySourceFiles*: seq[KeySourceFile]

  ChangesVM* = ref object of ViewModel
    source: AgentHarborDataSource
    tracker: ActionTracker
    scope*: ReviewScope
    loadToken: int
      ## The current load of the diff and its files.
    recordToken: int
      ## The current read of the record: a load's, or the reread after a
      ## confirmed write, which leaves the diff's file loads in flight.
    pending: int
    review: TaskReview
    recordLoaded: bool
    diff: SessionDiff
    diffOk: bool
    diffError: string
    fileStates: seq[(string, FileDiffView)]
    tabChosen: bool
    openCards: HashSet[string]
    diffCards: HashSet[string]
    revision*: Signal[int]
      ## Moves whenever the data changes the panel.
    readerRevision*: Signal[int]
      ## Moves whenever the reader opens or closes something.
    state*: Signal[AsyncState]
    error*: Signal[string]
    activeTab*: Signal[ReviewTab]
    milestone*: Signal[string]
      ## The milestone in scope; "" for all milestones.
    filter*: Signal[StatusFilter]
    query*: Signal[string]
    base*: Signal[string]
      ## The base the diff is shown against (`MergeBase` by default).
    selectedFile*: Signal[string]
    requestCard*: Signal[string]
      ## The card whose Request Changes input is open ("" for none).
    requestText*: Signal[string]
    editorRequest*: Signal[string]
    editorRequests*: Signal[int]
      ## Moves each time a file is asked to open in the editor.

proc newChangesVM*(source: AgentHarborDataSource; scope: ReviewScope;
                   tracker: ActionTracker = nil): ChangesVM =
  ## The change of `scope` (a task's plan and a session's diff) over
  ## `source`; nothing loads until `load`.
  withViewModel proc(dispose: proc()): ChangesVM =
    ChangesVM(source: source, scope: scope,
              tracker: (if tracker.isNil: newActionTracker() else: tracker),
              openCards: initHashSet[string](), diffCards: initHashSet[string](),
              revision: createSignal(0), readerRevision: createSignal(0),
              state: createSignal(asIdle), error: createSignal(""),
              activeTab: createSignal(rtSpecChanges), milestone: createSignal(""),
              filter: createSignal(sfAll), query: createSignal(""),
              base: createSignal(MergeBase), selectedFile: createSignal(""),
              requestCard: createSignal(""), requestText: createSignal(""),
              editorRequest: createSignal(""), editorRequests: createSignal(0))

proc tracker*(vm: ChangesVM): ActionTracker = vm.tracker

proc bump(vm: ChangesVM) =
  vm.revision.val = vm.revision.val + 1

proc bumpReader(vm: ChangesVM) =
  vm.readerRevision.val = vm.readerRevision.val + 1

# ---------------------------------------------------------------------------
# What is in scope
# ---------------------------------------------------------------------------

proc hasPlan*(vm: ChangesVM): bool =
  ## Tracked: the task has a plan (all four tabs) rather than only a diff.
  discard vm.revision.val
  vm.recordLoaded and vm.review.hasPlan

proc milestonesInScope(vm: ChangesVM): seq[ReviewMilestone] =
  if not vm.review.hasPlan: return @[]
  vm.review.record.scopeOf(vm.milestone.val)

proc milestoneChoices*(vm: ChangesVM): seq[(string, string)] =
  ## Tracked: the milestone selector: `All milestones` ("") then one entry
  ## per milestone of the record, as (id, label).
  discard vm.revision.val
  result.add ("", "All milestones")
  if vm.review.hasPlan:
    for m in vm.review.record.milestones:
      result.add (m.id, m.id & ": " & m.title)

proc reviewDiff(vm: ChangesVM): ChangeDiff =
  ## The change's file list with the hunks of every file loaded so far.
  result = vm.diff.diff
  for f in result.files.mitems:
    for (path, view) in vm.fileStates:
      if path == f.path and view.state == fdLoaded:
        f = view.file

proc tierCards(vm: ChangesVM): seq[SpecCard] =
  specCards(vm.milestonesInScope, vm.reviewDiff, hasPlan = vm.review.hasPlan,
            staged = vm.review.record.stagedCards)

proc tabList(vm: ChangesVM): seq[ReviewTab] =
  tabsOf(vm.recordLoaded and vm.review.hasPlan)

proc countOf(vm: ChangesVM; tab: ReviewTab): int =
  case tab
  of rtSpecChanges: vm.tierCards.len
  else: tabCount(tab, vm.milestonesInScope, [], vm.diff.diff)

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc settleLoad(vm: ChangesVM) =
  ## Both reads answered: the panel is ready, and on its first load opens on
  ## the first tab with content.
  if vm.pending > 0 or vm.state.val == asError: return
  vm.state.val = asReady
  let tabs = vm.tabList
  if not vm.tabChosen:
    var counts: seq[int]
    for t in tabs: counts.add vm.countOf(t)
    vm.activeTab.val = firstTabWithContent(tabs, counts)
    vm.tabChosen = true
  elif vm.activeTab.val notin tabs and tabs.len > 0:
    vm.activeTab.val = tabs[0]
  vm.bump()

proc setFileState(vm: ChangesVM; path: string; view: FileDiffView) =
  for entry in vm.fileStates.mitems:
    if entry[0] == path:
      entry[1] = view
      vm.bump()
      return
  vm.fileStates.add (path, view)
  vm.bump()

proc fetchFile(vm: ChangesVM; path: string; token: int;
               done: proc() {.closure.} = nil) =
  ## Loads one file's hunks for the load `token`; `done` once it answers.
  let at = vm.diff.diff.fileIndex(path)
  if at < 0: return
  let f = vm.diff.diff.files[at]
  if f.binary:
    vm.setFileState(path, FileDiffView(state: fdBinary, file: f))
    if not done.isNil: done()
    return
  vm.setFileState(path, FileDiffView(state: fdLoading, file: f))
  let target = vm
  vm.source.loadFileDiff(vm.scope.sessionId, vm.base.val, path,
    proc(answer: DataResult[ChangedFile]) =
      if token != target.loadToken: return
      if answer.ok:
        target.setFileState(path, FileDiffView(state: fdLoaded, file: answer.value))
      else:
        target.setFileState(path, FileDiffView(state: fdFailed, file: f,
                                               error: answer.error))
      if not done.isNil: done())

proc loadRecord(vm: ChangesVM) =
  inc vm.recordToken
  let token = vm.recordToken
  let target = vm
  vm.source.loadReviewRecord(vm.scope, proc(answer: DataResult[TaskReview]) =
    if token != target.recordToken: return
    dec target.pending
    if answer.ok:
      target.review = answer.value
      target.recordLoaded = true
    elif answer.missing:
      # A task with no plan: only the diff.
      target.review = TaskReview(hasPlan: false)
      target.recordLoaded = true
    else:
      target.error.val = answer.error
      target.state.val = asError
      target.bump()
      return
    target.settleLoad())

proc load*(vm: ChangesVM) =
  ## Loads the record and the diff's file list; `asLoading` until both
  ## answer. An answer to an older `load` is ignored.
  inc vm.loadToken
  let token = vm.loadToken
  vm.state.val = asLoading
  vm.error.val = ""
  vm.pending = 2
  vm.loadRecord()
  let target = vm
  vm.source.loadChangeDiff(vm.scope.sessionId, vm.base.val,
    proc(answer: DataResult[SessionDiff]) =
      if token != target.loadToken: return
      dec target.pending
      if answer.ok:
        target.diff = answer.value
        target.diffOk = true
        target.diffError = ""
        # Tiers 1 and 2 are read from the spec and governance files' hunks.
        for f in answer.value.diff.files:
          if f.hasHunks or f.binary: continue
          if f.path.isSpecFile or f.oldPath.isSpecFile or f.path.isGovernanceFile or
              f.oldPath.isGovernanceFile:
            inc target.pending
            target.fetchFile(f.path, token, proc() =
              dec target.pending
              target.settleLoad())
      else:
        target.diff = SessionDiff()
        target.diffOk = false
        target.diffError = answer.error
      target.settleLoad())

proc restart*(vm: ChangesVM) =
  ## Starts over: what the data put in is dropped and loads again; what the
  ## reader set is kept (a card, a file or a milestone that no longer exists
  ## is simply not shown).
  vm.review = TaskReview()
  vm.recordLoaded = false
  vm.diff = SessionDiff()
  vm.diffOk = false
  vm.diffError = ""
  vm.fileStates = @[]
  vm.bump()
  vm.load()

proc reloadRecord(vm: ChangesVM) =
  ## The record again, after a confirmed write; the diff and the reader's
  ## state stay.
  if vm.state.val != asReady: return
  vm.pending = 1
  vm.loadRecord()

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc notice*(vm: ChangesVM): string =
  ## Tracked: the notice a view centres instead of the active tab's content;
  ## "" when it shows content or the error block.
  discard vm.revision.val
  case vm.state.val
  of asLoading: ChangesLoadingNotice
  of asReady:
    case vm.activeTab.val
    of rtSpecChanges:
      if vm.countOf(rtSpecChanges) == 0: NoSpecChangesText else: ""
    of rtTests:
      if vm.countOf(rtTests) == 0: NoTestsText else: ""
    of rtImplementation:
      if vm.countOf(rtImplementation) == 0: NoImplementationDetailsText else: ""
    of rtCode:
      if not vm.diffOk: NoDiffDataText
      elif vm.diff.diff.files.len == 0: NoChangesText
      else: ""
  else: ""

proc tabs*(vm: ChangesVM): seq[ChangesTabView] =
  ## Tracked: the tab bar, in the reviewer's order, each with its count.
  discard vm.revision.val
  let active = vm.activeTab.val
  for t in vm.tabList:
    let n = vm.countOf(t)
    result.add ChangesTabView(tab: t, label: tabLabel(t), compactLabel: tabLabel(t, true),
                              count: n, empty: n == 0, active: t == active)

proc keyOf(card: SpecCard): string =
  case card.tier
  of stSpec: "spec:" & card.entry.milestoneId & ":" & card.entry.spec
  else:
    $card.tier & ":" & card.fromDiff.path & ":" & card.fromDiff.requirement &
      (if card.fromDiff.staged: ":staged" else: "")

proc requestFor(vm: ChangesVM; entry: SpecChange): string =
  for q in vm.review.approvalRequests:
    if q.spec == entry.spec and (q.milestoneId.len == 0 or q.milestoneId == entry.milestoneId):
      return q.feedbackId
  ""

proc actionTarget(vm: ChangesVM; path: string): string =
  "spec:" & vm.scope.taskId & ":" & path

proc specCards*(vm: ChangesVM): seq[SpecCardView] =
  ## Tracked: the Spec Changes tab, tier by tier (requirements, governance,
  ## specs), with each card's state and what the reader opened.
  discard vm.revision.val
  discard vm.readerRevision.val
  discard vm.tracker.revision.val
  for card in vm.tierCards:
    var v = SpecCardView(key: card.keyOf, tier: card.tier)
    case card.tier
    of stSpec:
      let e = card.entry
      v.title = e.spec
      v.path = e.spec
      v.summary = e.summary
      v.sections = e.sections
      v.commits = e.commits
      v.stateText = approvalText(e.approval)
      v.stateRole =
        case e.approval.state
        of apPending: "warning"
        of apApproved: "success"
        of apEditorial, apUnstructured: "quiet"
        of apMalformed: "error"
      v.canApprove = e.approval.state == apPending and vm.requestFor(e).len > 0
    else:
      let c = card.fromDiff
      v.title = if c.requirement.len > 0: c.heading else: c.path
      v.path = c.path
      v.origin = c.origin
      v.staged = c.staged
      v.stateText = if c.staged: "staged" else: $c.change
      v.stateRole = if c.staged: "warning" else: "quiet"
    v.open = v.key in vm.openCards
    v.showsDiff = v.key in vm.diffCards
    v.requestOpen = vm.requestCard.val == v.key
    let entry = vm.tracker.entryOf(vm.actionTarget(v.path))
    v.action = entry.status
    v.actionReason = entry.reason
    result.add v

proc cardDiff*(vm: ChangesVM; key: string): seq[DiffHunk] =
  ## Tracked: the hunks a card's Diff side shows: a tier-1 or tier-2 card's
  ## own hunks, a spec card's file's hunks once that file is loaded.
  discard vm.revision.val
  for card in vm.tierCards:
    if card.keyOf != key: continue
    if card.tier != stSpec: return card.fromDiff.hunks
    for (path, view) in vm.fileStates:
      if path == card.entry.spec: return view.file.hunks
    let found = vm.diff.diff.specDiff(card.entry.spec)
    if found.found: return found.file.hunks

proc tests*(vm: ChangesVM): seq[TestGroup] =
  ## Tracked: the Tests tab, by milestone, failing first.
  discard vm.revision.val
  testGroups(vm.milestonesInScope)

proc details*(vm: ChangesVM): seq[DetailsView] =
  ## Tracked: the Implementation Details tab: each milestone's notes, as
  ## written, and its key source files.
  discard vm.revision.val
  for m in vm.milestonesInScope:
    if m.implementationDetails.len == 0 and m.keySourceFiles.len == 0: continue
    result.add DetailsView(milestoneId: m.id, title: m.title,
                           notes: m.implementationDetails,
                           keySourceFiles: m.keySourceFiles)

proc bases*(vm: ChangesVM): seq[DiffBase] =
  ## Tracked: the base selector's choices; one choice means no selector.
  discard vm.revision.val
  vm.diff.bases

proc baseLabel*(vm: ChangesVM): string =
  discard vm.revision.val
  vm.diff.base.label

proc shownFiles(vm: ChangesVM): seq[ChangedFile] =
  let keys = keySourcePaths(vm.milestonesInScope)
  filterFiles(orderKeyFilesFirst(vm.diff.diff.files, keys), vm.filter.val, vm.query.val)

proc files*(vm: ChangesVM): seq[FileRow] =
  ## Tracked: the Code tab's rows: key source files first, then the diff's
  ## order, through the filter and the search.
  discard vm.revision.val
  let keys = keySourcePaths(vm.milestonesInScope)
  let selected = vm.selectedFile.val
  for f in vm.shownFiles:
    result.add FileRow(file: f, key: f.isKeyFile(keys), counts: countsText(f.added, f.removed),
                       selected: f.path == selected)

proc filesNotice*(vm: ChangesVM): string =
  ## Tracked: `No files match the current filters` when the filter hides
  ## every file of a change that has some.
  discard vm.revision.val
  if vm.diffOk and vm.diff.diff.files.len > 0 and vm.shownFiles.len == 0:
    NoMatchingFilesText
  else: ""

proc summaryLine*(vm: ChangesVM): string =
  ## Tracked: `3 files changed +12 −3`, `No changes`, `No diff data`.
  discard vm.revision.val
  summaryText(vm.diff.diff, vm.diffOk)

proc rollUp*(vm: ChangesVM; ended: bool): string =
  ## Tracked: the session's `n files +a −r` beside its name, for an ended
  ## session with changes; "" otherwise.
  discard vm.revision.val
  rollUpText(vm.diff.diff, ended, vm.diffOk)

proc fileDiff*(vm: ChangesVM; path: string): FileDiffView =
  ## Tracked: one file's diff and its state.
  discard vm.revision.val
  for (p, view) in vm.fileStates:
    if p == path: return view
  let at = vm.diff.diff.fileIndex(path)
  if at >= 0:
    let f = vm.diff.diff.files[at]
    FileDiffView(state: (if f.binary: fdBinary else: fdNotLoaded), file: f)
  else:
    FileDiffView(state: fdFailed, error: "the change does not touch " & path)

proc selectedPosition*(vm: ChangesVM): string =
  ## Tracked: the selected file's `n of m` among the files shown.
  discard vm.revision.val
  let shown = vm.shownFiles
  var at = -1
  for i, f in shown:
    if f.path == vm.selectedFile.val: at = i
  positionText(at, shown.len)

# ---------------------------------------------------------------------------
# The reader's actions
# ---------------------------------------------------------------------------

proc selectTab*(vm: ChangesVM; tab: ReviewTab) =
  vm.tabChosen = true
  vm.activeTab.val = tab

proc selectMilestone*(vm: ChangesVM; milestoneId: string) =
  ## "" for all milestones.
  vm.milestone.val = milestoneId
  vm.bump()

proc toggleCard*(vm: ChangesVM; key: string) =
  if key in vm.openCards: vm.openCards.excl key else: vm.openCards.incl key
  vm.bumpReader()

proc toggleDiff*(vm: ChangesVM; key: string) =
  ## A card's Summary ⇄ Diff side.
  if key in vm.diffCards: vm.diffCards.excl key else: vm.diffCards.incl key
  vm.bumpReader()

proc setFilter*(vm: ChangesVM; filter: StatusFilter) = vm.filter.val = filter
proc setQuery*(vm: ChangesVM; query: string) = vm.query.val = query

proc selectBase*(vm: ChangesVM; base: string) =
  ## Shows the change against another base; the file list loads again.
  if base == vm.base.val: return
  vm.base.val = base
  vm.fileStates = @[]
  if vm.state.val == asReady or vm.state.val == asError: vm.load()

proc loadFile*(vm: ChangesVM; path: string) =
  ## Loads one file's hunks (a binary file has none to load).
  vm.fetchFile(path, vm.loadToken)

proc selectFile*(vm: ChangesVM; path: string) =
  ## Selects a file and loads its diff when it is not loaded yet.
  vm.selectedFile.val = path
  if vm.fileDiff(path).state == fdNotLoaded: vm.loadFile(path)

proc stepFile*(vm: ChangesVM; delta: int): bool =
  ## The previous or next file among those shown; false at either end.
  let shown = vm.shownFiles
  var at = -1
  for i, f in shown:
    if f.path == vm.selectedFile.val: at = i
  let to = if at < 0: (if delta > 0: 0 else: shown.high) else: at + delta
  if to < 0 or to > shown.high: return false
  vm.selectFile(shown[to].path)
  true

proc openInEditor*(vm: ChangesVM; path: string) =
  ## Asks the host to open `path` as a unified-diff editor tab.
  vm.editorRequest.val = path
  vm.editorRequests.val = vm.editorRequests.val + 1

# ---------------------------------------------------------------------------
# The writes
# ---------------------------------------------------------------------------

proc cardOf(vm: ChangesVM; key: string): tuple[found: bool, card: SpecCard] =
  for card in vm.tierCards:
    if card.keyOf == key: return (true, card)
  (false, SpecCard())

proc send(vm: ChangesVM; action: OperatorAction): bool =
  let target = vm
  vm.tracker.submit(vm.source, action, proc(entry: TrackedAction) =
    if entry.status == astConfirmed: target.reloadRecord())

proc approve*(vm: ChangesVM; key: string): bool =
  ## Approves a pending spec change through the feedback request open for
  ## it; false when it has none.
  let c = vm.cardOf(key)
  if not c.found or c.card.tier != stSpec: return false
  let feedbackId = vm.requestFor(c.card.entry)
  if c.card.entry.approval.state != apPending or feedbackId.len == 0: return false
  vm.send(approveSpecChange(vm.scope.taskId, c.card.entry.milestoneId,
                            c.card.entry.spec, feedbackId))

proc openRequestChanges*(vm: ChangesVM; key: string) =
  ## Opens the Request Changes input under a card (closing any other).
  vm.requestCard.val = key
  vm.requestText.val = ""

proc closeRequestChanges*(vm: ChangesVM) =
  vm.requestCard.val = ""
  vm.requestText.val = ""

proc setRequestText*(vm: ChangesVM; text: string) = vm.requestText.val = text

proc submitRequestChanges*(vm: ChangesVM): bool =
  ## Sends the open input's text as a change request on its card; false
  ## with nothing typed or no input open.
  let c = vm.cardOf(vm.requestCard.val)
  if not c.found or vm.requestText.val.strip.len == 0: return false
  let path = if c.card.tier == stSpec: c.card.entry.spec else: c.card.fromDiff.path
  let milestoneId = if c.card.tier == stSpec: c.card.entry.milestoneId else: ""
  vm.send(requestSpecChanges(vm.scope.taskId, milestoneId, path, vm.requestText.val))

proc revert*(vm: ChangesVM; key: string): bool =
  ## Undo / Revert a spec change.
  let c = vm.cardOf(key)
  if not c.found or c.card.tier != stSpec: return false
  vm.send(revertSpecChange(vm.scope.taskId, c.card.entry.milestoneId, c.card.entry.spec))

proc applyStaged*(vm: ChangesVM; key: string): bool =
  ## Approve & Apply a staged card.
  let c = vm.cardOf(key)
  if not c.found or not c.card.fromDiff.staged: return false
  vm.send(operator_actions.applyStaged(vm.scope.taskId, c.card.fromDiff.path))

proc discardStaged*(vm: ChangesVM; key: string): bool =
  let c = vm.cardOf(key)
  if not c.found or not c.card.fromDiff.staged: return false
  vm.send(operator_actions.discardStaged(vm.scope.taskId, c.card.fromDiff.path))
