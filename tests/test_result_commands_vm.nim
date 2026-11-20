## The omnibox's result commands viewmodel (`ResultCommandsVM`) over its
## two seams -- the search providers of `/search` and Agent Harbor's
## input-command protocol: groups filling in as providers answer, a
## superseded query's rows dropped at once, a failing provider, nothing
## matching, `+N more` and a group alone, `/ah` from the discovery, a
## command by name and by alias, an unknown name, Agent Harbor
## unreachable, an extension's command listed, run and gone, rich rows and
## their text form, opening each kind of row, completions, the launcher's
## abilities, and answers after disposal.
##
## No test doubles beyond the seams' own implementations:
## `ScriptedSearchProvider` (rows computed from the text, held until
## released where a test needs a provider still searching) and
## `ScriptedCommandSource` (a discovery answer in Agent Harbor's documented
## shape, rows by command and text) -- what the prototype's stories use,
## because no live provider or Agent Harbor search is wired. Every
## expectation is written out by hand. The data is invented (an upload
## client's retry work).

import std/[strutils, unittest]
import nim_agents_isonim_viewmodels

const Discovery = """{"commands": [
  {"id": "search", "aliases": ["s"], "title": "Search sessions",
   "description": "Sessions whose prompt, messages or files match the text",
   "kind": "results", "source": "builtin"},
  {"id": "search-chats", "aliases": ["sc"], "title": "Search chats",
   "description": "Web chats whose history matches the text", "kind": "results",
   "source": "builtin"},
  {"id": "runbooks", "aliases": ["rb"], "title": "Search runbooks",
   "description": "Runbook sections that mention the text", "kind": "results",
   "source": "extension:runbook-index"}
]}"""

const Files = ["src/upload/retry.py", "src/upload/client.py", "tests/test_retry.py"]

proc fileRows(text: string): seq[ResultRow] =
  for f in Files:
    if f.matches(text):
      result.add ResultRow(id: f, kind: rkFile, title: f, location: f, source: "builtin")

proc symbolRows(text: string): seq[ResultRow] =
  for (name, line) in [("retry_once", 12), ("retry_with_jitter", 30), ("upload", 4)]:
    if name.matches(text):
      result.add ResultRow(id: name, kind: rkSymbol, title: name, subtitle: "function",
                           location: "src/upload/retry.py:" & $line, source: "builtin")

proc commandRows(command, text: string): seq[ResultRow] =
  case command
  of "search":
    for (id, title) in [("ses-1", "Retry uploads with jitter"), ("ses-2", "Retry downloads")]:
      if title.matches(text):
        result.add ResultRow(id: id, kind: rkSession, title: title,
                             subtitle: "upload-client · Codex · running",
                             url: "agent-harbor://task/" & id, source: "builtin",
                             html: "<p>2 tests passing</p>", trusted: true)
  of "runbooks":
    if "retry".matches(text):
      result.add ResultRow(id: "rb-1", kind: rkSpec, title: "Runbook: retrying uploads",
                           url: "https://runbooks.example.invalid/retrying-uploads",
                           source: "extension:runbook-index",
                           html: "<p>Steps</p><script>document.body.append('x')</script>")
  else: discard

type Fixture = object
  vm: ResultCommandsVM
  files, symbols: ScriptedSearchProvider
  harbor: ScriptedCommandSource
  opened: seq[(string, OpenTarget)]

proc fixture(unreachable = ""): ref Fixture =
  result = new Fixture
  let d = parseDiscovery(Discovery, [("runbook-index", "Runbook index")])
  doAssert d.ok
  result.harbor = newScriptedCommandSource(d.commands, commandRows)
  result.harbor.unreachable = unreachable
  result.files = newScriptedSearchProvider("files", "Files", fileRows)
  result.symbols = newScriptedSearchProvider("symbols", "Symbols", symbolRows)
  result.vm = newResultCommandsVM([SearchProvider(result.files), result.symbols,
                                   newAgentHarborSearchProvider(result.harbor)],
                                  result.harbor)
  result.vm.agents = @["Claude", "Codex", "Opencode"]
  result.vm.repositories = @["upload-client"]
  result.vm.files = @Files
  result.vm.workflows = @["test-retry", "record-failing-test"]
  result.vm.capabilities = @["research", "think", "stream"]
  let f = result
  result.vm.onOpen = proc(row: ResultRow; target: OpenTarget) =
    f.opened.add (row.id, target)

proc ids(g: ShownGroup): seq[string] =
  for r in g.rows: result.add r.id

proc groupIds(vm: ResultCommandsVM): seq[string] =
  for g in vm.groups: result.add g.group.id

suite "/search over every provider":
  test "each group fills in as its provider answers, in the providers' order":
    let f = fixture()
    f.symbols.hold = true
    f.vm.setInput("/s retry")
    check f.vm.kind == qkSearch
    check f.vm.groupIds == @["files", "symbols", "agent-harbor-search"]
    check f.vm.groups[1].group.state == psSearching
    check f.vm.groups[1].rows.len == 0
    check f.vm.groups[0].ids == @["src/upload/retry.py", "tests/test_retry.py"]
    check f.vm.headerText == "Searching\xE2\x80\xA6 2 of 3 providers answered"
    f.symbols.release()
    check f.vm.groups[1].ids == @["retry_once", "retry_with_jitter"]
    check f.vm.headerText == "6 results from 3 providers \xC2\xB7 Enter opens"
    check f.files.asked == @["retry"]
    check f.harbor.queried[0].command == "search"   # Agent Harbor's search as a provider

  test "a superseded query's rows are dropped at once":
    let f = fixture()
    f.vm.setInput("/s retry")
    check f.vm.groups[1].rows.len == 2
    f.symbols.hold = true
    f.vm.setInput("/s retry jitter")
    # The slow provider answered the older text; none of its rows stand.
    check f.vm.groups[1].group.state == psSearching
    check f.vm.groups[1].rows.len == 0
    check f.vm.groups[2].ids == @["ses-1"]
    f.symbols.release()
    check f.vm.groups[1].ids == @["retry_with_jitter"]

  test "an answer to an older query that arrives late changes nothing":
    let f = fixture()
    f.symbols.hold = true
    f.vm.setInput("/s retry")
    f.vm.setInput("/s upload")
    check f.symbols.pendingAnswers == 2
    f.symbols.releaseOne()               # the answer to "retry"
    check f.vm.groups[1].group.state == psSearching
    check f.vm.groups[1].rows.len == 0
    f.symbols.releaseOne()               # the answer to "upload"
    check f.vm.groups[1].ids == @["upload"]

  test "a failing provider says why; the others still answer":
    let f = fixture()
    f.harbor.failures = @[("search", "Agent Harbor is not reachable")]
    f.vm.setInput("/s retry")
    check f.vm.groups[2].group.stateWord == "failed: Agent Harbor is not reachable"
    check f.vm.groups[0].rows.len == 2
    check f.vm.headerText == "4 results from 2 of 3 providers \xC2\xB7 Agent Harbor sessions failed \xC2\xB7 Enter opens"
    check f.vm.headerRole == "error"

  test "nothing matches: one line in place of the groups":
    let f = fixture()
    f.vm.setInput("/s warp drive")
    check f.vm.groups.len == 0
    check f.vm.notice.text == "Nothing matches \xE2\x80\x9Cwarp drive\xE2\x80\x9D"
    check f.vm.headerText == "Searched 3 providers"

  test "+N more, a group alone and back":
    let f = fixture()
    f.files.answer = proc(text: string): seq[ResultRow] =
      for i in 1 .. 11:
        result.add ResultRow(id: "f" & $i, kind: rkFile, title: "src/retry_" & $i & ".py")
    f.vm.setInput("/s retry")
    check f.vm.groups[0].rows.len == GroupRowLimit
    check f.vm.groups[0].more == 3
    check f.vm.groups[1].first == GroupRowLimit   # selection runs on through the next group
    f.vm.showGroup("files")
    check f.vm.groupIds == @["files"]
    check f.vm.groups[0].rows.len == 11
    check f.vm.groups[0].more == 0
    check f.vm.headerText == "Files \xC2\xB7 11 results \xC2\xB7 Enter opens"
    f.vm.showAll()
    check f.vm.groupIds.len == 3
    f.vm.showGroup("nothing-by-this-id")
    check f.vm.groupIds.len == 3

  test "the selection moves through every row drawn, wrapping":
    let f = fixture()
    f.vm.setInput("/s retry")
    let n = f.vm.selectableRows.len
    check n == 6
    f.vm.moveSelection(-1)
    check f.vm.selected.val == n - 1
    f.vm.moveSelection(1)
    check f.vm.selected.val == 0
    f.vm.moveSelection(3)
    check f.vm.selectedRow.id == "retry_with_jitter"
    check f.vm.isSelected(f.vm.groups[1], 1)
    f.vm.setInput("/s upload")
    check f.vm.selected.val == 0

suite "Agent Harbor's commands":
  test "/ah lists every command with its source":
    let f = fixture()
    f.vm.setInput("/ah")
    check f.vm.kind == qkAhList
    check f.vm.groups[0].ids == @["search", "search-chats", "runbooks"]
    let rows = f.vm.groups[0].rows
    check rows[0].title == "/ah-search"
    check f.vm.aliasesOf(rows[0]) == "/ahs"
    check f.vm.rowTag(rows[0]) == "Agent Harbor"
    check f.vm.rowTag(rows[2]) == "Runbook index"
    check f.vm.headerText == "Agent Harbor commands \xC2\xB7 Enter chooses one"
    f.vm.setInput("/ah-sea")
    check f.vm.groups[0].ids == @["search", "search-chats"]

  test "choosing a command puts its name into the field":
    let f = fixture()
    f.vm.setInput("/ah")
    f.vm.open(2)
    check f.vm.input == "/ah-runbooks "
    check f.vm.kind == qkAhRun
    check f.opened.len == 0

  test "by name and by alias, the same command":
    let f = fixture()
    f.vm.setInput("/ah-search jitter")
    check f.vm.kind == qkAhRun
    check f.vm.groups[0].ids == @["ses-1"]
    check f.vm.headerText == "/ah-search \xC2\xB7 Search sessions \xC2\xB7 Agent Harbor"
    f.vm.setInput("/ahs jitter")
    check f.vm.groups[0].ids == @["ses-1"]
    check f.vm.headerText == "/ahs is /ah-search \xC2\xB7 Search sessions \xC2\xB7 Agent Harbor"
    check f.harbor.queried[^1].command == "search"
    check f.harbor.queried[^1].text == "jitter"

  test "an unknown name says so, with where the list is":
    let f = fixture()
    f.vm.setInput("/ah-sessions retry")
    check f.vm.kind == qkAhUnknown
    check f.vm.groups.len == 0
    check f.vm.notice.text == "No Agent Harbor command named /ah-sessions"
    check f.vm.notice.hint == "/ah lists them"
    check f.vm.notice.term == "/ah-sessions"

  test "Agent Harbor unreachable: the error in place of the rows":
    let f = fixture(unreachable = "GET /api/v1/input-commands failed: connection refused")
    f.vm.setInput("/ah")
    check f.vm.discoveryState == dsFailed
    check f.vm.groups.len == 0
    check f.vm.notice.role == "error"
    check f.vm.notice.text ==
      "Agent Harbor is not reachable: GET /api/v1/input-commands failed: connection refused"
    f.vm.setInput("/ahs retry")
    check f.vm.notice.role == "error"

  test "an extension's command is listed, run, and gone once disabled":
    let f = fixture()
    f.vm.setInput("/ahrb retry")
    check f.vm.kind == qkAhRun
    check f.vm.groups[0].ids == @["rb-1"]
    check f.vm.rowTag(f.vm.groups[0].rows[0]) == "Runbook index"
    f.harbor.disableExtension("runbook-index")
    f.vm.refreshCommands()
    check f.vm.kind == qkAhUnknown          # the open query is read again
    f.vm.setInput("/ah")
    check f.vm.groups[0].ids == @["search", "search-chats"]

  test "the discovery's answer after disposal changes nothing":
    let f = fixture()
    f.vm.setInput("/ah")
    let before = f.vm.revision.val
    f.vm.dispose()
    f.harbor.unreachable = "gone"
    f.vm.refreshCommands()
    check f.vm.revision.val == before

suite "rich rows":
  test "a box where HTML is on, its text form where it is off":
    let f = fixture()
    f.vm.setInput("/ahs jitter")
    let r = f.vm.groups[0].rows[0]
    check f.vm.showsHtml(r)
    check not f.vm.scriptsBlocked(r)          # a built-in command: trusted
    check htmlHeightOf(r) == DefaultHtmlHeight
    check htmlHeightOf(ResultRow(htmlHeight: 600)) == MaxHtmlHeight
    f.vm.setHtmlEnabled(false)
    check not f.vm.showsHtml(r)
    check f.vm.headerText.endsWith("Rich\xC2\xA0results\xC2\xA0shown\xC2\xA0as\xC2\xA0text")
    # Only where a row has a rich form: a query whose rows have none says
    # nothing about it.
    f.vm.setInput("/s client")
    check f.vm.groups[0].rows.len == 1
    check "Rich" notin f.vm.headerText

  test "an untrusted box's script is not run, and that is said":
    let f = fixture()
    f.vm.setInput("/ahrb retry")
    let r = f.vm.groups[0].rows[0]
    check f.vm.showsHtml(r)
    check f.vm.scriptsBlocked(r)

suite "opening a row":
  test "each kind opens where it says, and the header says what was opened":
    let f = fixture()
    f.vm.setInput("/s retry")
    f.vm.openSelected()
    check f.opened == @[("src/upload/retry.py", otEditor)]
    check f.vm.headerText == "Opened src/upload/retry.py"
    check f.vm.headerRole == "body"
    f.vm.setInput("/s jitter")
    let session = f.vm.selectableRows.len - 1
    f.vm.open(session)
    check f.opened[^1] == ("ses-1", otSessionTab)
    check f.vm.headerText == "Opened Retry uploads with jitter as a tab"

  test "a URL CodeTracer cannot open goes to the system, and the row says so":
    let f = fixture()
    f.vm.setInput("/ahrb retry")
    let r = f.vm.groups[0].rows[0]
    check not f.vm.openedOutside(r)
    f.vm.open(0)
    check f.opened == @[("rb-1", otOutside)]
    check f.vm.openedOutside(r)
    check f.vm.headerText == "Opened outside CodeTracer: https://runbooks.example.invalid/retrying-uploads"
    f.vm.setInput("/ahrb retry ")
    check not f.vm.openedOutside(r)            # a new query forgets it

suite "completions in an instruction":
  test "@ lists agents, repositories and files; Tab inserts one":
    let f = fixture()
    f.vm.setInput("/ai Run the retry test with @")
    check f.vm.kind == qkCompletion
    check f.vm.groupIds == @["agents", "repositories", "files"]
    check f.vm.headerText == "Completing @ \xC2\xB7 Tab inserts it"
    f.vm.setInput("/ai Run the retry test with @co")
    check f.vm.groupIds == @["agents"]
    check f.vm.groups[0].ids == @["agent:Codex", "agent:Opencode"]
    check f.vm.insertSelected()
    check f.vm.input == "/ai Run the retry test with @Codex "
    check f.vm.kind == qkNone

  test "/ lists workflows and chat capabilities":
    let f = fixture()
    f.vm.setInput("/ai Check the backoff and /")
    check f.vm.groupIds == @["workflows", "capabilities"]
    f.vm.setInput("/ai Check the backoff and /th")
    check f.vm.groups[0].ids == @["capability:think"]
    f.vm.setInput("/ai Check the backoff and /zz")
    check f.vm.groups.len == 0
    check f.vm.notice.text == "Nothing completes /zz"

suite "the launcher's abilities (OMNI-AREQ5)":
  test "each ability's route reaches something the omnibox shows":
    let f = fixture()
    var unreached: seq[string]
    for a in LauncherAbilities:
      f.vm.setInput(a.route)
      let shows = f.vm.kind != qkAhUnknown and
                  (f.vm.kind != qkNone or a.route.startsWith(AgentPrefix))
      if not shows: unreached.add a.ability
    check unreached.len == 0
    check unroutedAbilities(LauncherAbilities, f.vm.commandList).len == 0

  test "an ability whose route is gone is reported by name":
    let f = fixture(unreachable = "connection refused")
    let missing = unroutedAbilities(LauncherAbilities, f.vm.commandList)
    check missing == @["run an input command by its name", "run an input command by its alias"]
