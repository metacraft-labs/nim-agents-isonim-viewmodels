## `NodeHarborFollower` on Node against a real, private Agent Harbor server,
## and a window's `HostFedDataSource` fed with what it posts: the two halves
## of a desktop app's session list (manager decision D92, the main process
## follows the server and forwards to each window).
##
## No mocks: each case starts `ah server start` through nim-agent-harbor's
## `testing/real_server` (fresh state, loopback, its own API key) and runs
## `tests/probes/node_follower_probe.nim`, compiled for Node once here, as
## the app's main process: a real `fetch` against the real server. The probe
## writes every message it posts as the text IPC carries; this test reads
## those lines, and the fed cases decode them into a `HostFedDataSource`
## with the session strip over it, as a window does.
##
## Checks sit outside the reactive roots: a `check` inside a closure records
## its failure in a global and the case still reports OK.
##
## When no `ah` binary or no `node` is available every case is skipped with
## the reason printed. Native (the test); the follower under test is
## JavaScript.

import std/[json, monotimes, net, os, osproc, sequtils, streams, strutils, times,
            unittest]
import isonim/core/owner
import nim_agent_harbor
import nim_agent_harbor/testing/real_server
import nim_agents_isonim_viewmodels
import nim_agents_isonim_viewmodels/agent_harbor/host_fed_source

const
  apiKey = "viewmodels-node-follower-key"
  SelfSource = currentSourcePath()
  CompilerAtBuild = getCurrentCompilerExe()
  ProbeRel = "tests/probes/node_follower_probe.nim"
  SiblingSources = ["nim-agents", "nim-agent-harbor", "nim-acp",
                    "nim-everywhere", "isonim"]
    ## The `--path:` siblings the Justfile passes.

let
  root = SelfSource.parentDir.parentDir
  nimExe = if fileExists(CompilerAtBuild): CompilerAtBuild else: findExe("nim")
  nodeExe = findExe("node")
  binary = serverBinary()
  workDir = getTempDir() / ("vm-node-follower-" & $getCurrentProcessId())

proc compileProbe(): string =
  ## The probe compiled for Node, or "" with the compiler's output printed.
  createDir(workDir)
  result = workDir / "node_follower_probe.js"
  var args = @["js", "-d:nodejs", "--hints:off", "--warnings:off",
               "--path:src"]
  for sibling in SiblingSources: args.add("--path:../" & sibling & "/src")
  args.add("--nimcache:" & (workDir / "nimcache"))
  args.add("-o:" & result)
  args.add(ProbeRel)
  let p = startProcess(nimExe, workingDir = root, args = args,
                       options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  if p.waitForExit() != 0 or not fileExists(result):
    echo output
    result = ""
  p.close()

let probeJs = if binary.len > 0 and nodeExe.len > 0: compileProbe() else: ""

template needsServer(body: untyped) =
  if binary.len == 0:
    echo "SKIPPED: no Agent Harbor server binary: `ah` is not on PATH and " &
      "AH_SERVER_BIN is unset"
    skip()
  elif nodeExe.len == 0:
    echo "SKIPPED: no `node` on PATH to run the follower"
    skip()
  else:
    check probeJs.len > 0   # the probe compiled
    if probeJs.len > 0:
      body

type Probe = object
  process: Process
  outFile: string

proc startProbePiped(baseUrl, key: string; after = "";
                     readTimeoutMs = 30_000): Probe =
  result.outFile = workDir / ("out-" & $getMonoTime().ticks & ".jsonl")
  writeFile(result.outFile, "")
  result.process = startProcess(nodeExe, args = [probeJs, baseUrl,
    (if key.len > 0: key else: "-"), result.outFile, after, $readTimeoutMs],
    options = {poStdErrToStdOut})

proc command(probe: Probe; line: string) =
  probe.process.inputStream.write(line & "\n")
  probe.process.inputStream.flush()

proc stop(probe: Probe) =
  try:
    probe.command("exit")
  except CatchableError:
    discard
  discard probe.process.waitForExit(5_000)
  probe.process.close()

proc lines(probe: Probe): seq[JsonNode] =
  ## Every line the probe wrote so far, parsed.
  for line in readFile(probe.outFile).splitLines:
    if line.len > 0: result.add parseJson(line)

proc messages(probe: Probe): seq[HostMessage] =
  ## The follower's messages so far, decoded as a window decodes them.
  for line in readFile(probe.outFile).splitLines:
    if line.len > 0 and not line.contains("\"probe\""):
      result.add decodeHostMessage(line)

proc waitFor(probe: Probe; done: proc(messages: seq[HostMessage]): bool;
             seconds = 30): bool =
  let deadline = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < deadline:
    if done(probe.messages): return true
    sleep(50)
  false

proc gitRepo(dir: string) =
  createDir(dir)
  doAssert execShellCmd("git init -q -b main " & quoteShell(dir)) == 0
  doAssert execShellCmd("git -C " & quoteShell(dir) &
    " -c user.name=node -c user.email=node@example.invalid" &
    " commit -q --allow-empty -m init") == 0

proc createSession(server: RealServer; prompt = "node follower probe"): string =
  ## Creates a session through an independent native client.
  let repoDir = server.root / "repo"
  if not dirExists(repoDir): gitRepo(repoDir)
  let creator = newHarborClient(server.baseUrl, nativeTransport(),
    apiKeyAuth(apiKey))
  let created = creator.createTask(probeTask(repoDir, prompt))
  doAssert created.sessionIds.len == 1
  created.sessionIds[0]

proc fleetOf(messages: seq[HostMessage]; loadId: int): seq[HostMessage] =
  messages.filterIt(it.kind == hmFleet and it.loadId == loadId)

proc framesOf(messages: seq[HostMessage]; event: string): seq[HostMessage] =
  messages.filterIt(it.kind == hmFrame and it.event == event)

suite "NodeHarborFollower against a real server":
  test "a listing is the server's sessions, and the feed is followed":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let id = server.createSession()
      let probe = startProbePiped(server.baseUrl, apiKey)
      defer: probe.stop()
      probe.command("load 1 200")
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.fleetOf(1).len > 0 and m.anyIt(it.kind == hmConnected))
      let got = probe.messages
      let fleet = got.fleetOf(1)
      check fleet.len == 1
      check fleet[0].ok
      let page = parseJson(fleet[0].text)
      check page["items"].getElems.mapIt(it["id"].getStr) == @[id]
      check page["total"].getInt == 1
      check got[0].kind == hmConnecting
      # The first frame of a feed opened with no cursor is the server's resync.
      check got.framesOf("resync").len >= 1

  test "a refused listing and a refused feed are errors, never an empty fleet":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      discard server.createSession()
      let probe = startProbePiped(server.baseUrl, "")   # no key
      defer: probe.stop()
      probe.command("load 7 200")
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.fleetOf(7).len > 0 and
          m.filterIt(it.kind == hmConnecting).len >= 2)
      let got = probe.messages
      let fleet = got.fleetOf(7)
      check fleet.len == 1
      check not fleet[0].ok
      check "401" in fleet[0].text
      let refused = got.filterIt(it.kind == hmDisconnected)
      check refused.len >= 1
      check "401" in refused[0].text
      check not got.anyIt(it.kind == hmConnected)

  test "a session created while following arrives as its lifecycle frame":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let probe = startProbePiped(server.baseUrl, apiKey)
      defer: probe.stop()
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.anyIt(it.kind == hmConnected))
      let id = server.createSession()
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.framesOf("lifecycle").anyIt(id in it.data))
      let frame = probe.messages.framesOf("lifecycle").filterIt(id in it.data)[0]
      check frame.id.len > 0
      check parseJson(frame.data)["kind"].getStr == "session_created"

  test "a follower given the last cursor resumes without a resync":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let first = startProbePiped(server.baseUrl, apiKey)
      let id = server.createSession()
      check first.waitFor(proc(m: seq[HostMessage]): bool =
        m.framesOf("lifecycle").anyIt(id in it.data))
      let cursor = first.messages.framesOf("lifecycle")[^1].id
      first.stop()
      let second = startProbePiped(server.baseUrl, apiKey, after = cursor)
      defer: second.stop()
      check second.waitFor(proc(m: seq[HostMessage]): bool =
        m.framesOf("caught_up").len > 0)
      check second.messages.framesOf("resync").len == 0

  test "a server that comes up later is followed":
    needsServer:
      let port = freePort()
      let probe = startProbePiped("http://127.0.0.1:" & $port.int, apiKey)
      defer: probe.stop()
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.filterIt(it.kind == hmDisconnected).len >= 2)
      check not probe.messages.anyIt(it.kind == hmConnected)
      let server = startServer(binary, apiKey, port = port)
      defer: server.stop()
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.anyIt(it.kind == hmConnected))

  test "after close nothing is posted":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let probe = startProbePiped(server.baseUrl, apiKey)
      defer: probe.stop()
      check probe.waitFor(proc(m: seq[HostMessage]): bool =
        m.anyIt(it.kind == hmConnected))
      probe.command("close")
      let deadline = getMonoTime() + initDuration(seconds = 10)
      while getMonoTime() < deadline and
          not probe.lines.anyIt(it{"probe"}.getStr == "closed"):
        sleep(50)
      let atClose = probe.lines.len
      probe.command("load 9 200")
      discard server.createSession()
      sleep(2_000)
      let after = probe.lines
      check after.len == atClose
      check after[^1]{"probe"}.getStr == "closed"

suite "a window fed by the Node follower":
  test "the strip lists the server's sessions, and a new one from its frame":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      let before = server.createSession("listed before the window opened")
      let probe = startProbePiped(server.baseUrl, apiKey)
      defer: probe.stop()
      var delivered = 0
      var states: seq[AsyncState]
      var listed: seq[seq[string]]
      var later = ""
      createRoot proc(disposeRoot: proc()) =
        let source = newHostFedDataSource(
          proc(loadId, pageSize: int) =
            probe.command("load " & $loadId & " " & $pageSize),
          label = "live: " & server.baseUrl)
        let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
        proc pumpUntil(done: proc(): bool) =
          let deadline = getMonoTime() + initDuration(seconds = 30)
          while getMonoTime() < deadline and not done():
            let got = probe.messages
            while delivered < got.len:
              discard source.deliver(got[delivered])
              inc delivered
            sleep(50)
        vm.load()
        pumpUntil(proc(): bool = vm.state.val == asReady)
        states.add vm.state.val
        listed.add vm.listedSessions.mapIt(it.id)
        later = server.createSession("created while the window is open")
        pumpUntil(proc(): bool = vm.listedSessions.anyIt(it.id == later))
        listed.add vm.listedSessions.mapIt(it.id)
        vm.dispose()
        source.close()
        disposeRoot()
      check states == @[asReady]
      check listed[0] == @[before]
      check later in listed[1]
      check before in listed[1]

  test "a refused server is the strip's error, not an empty list":
    needsServer:
      let server = startServer(binary, apiKey)
      defer: server.stop()
      discard server.createSession()
      let probe = startProbePiped(server.baseUrl, "")
      defer: probe.stop()
      var state = asIdle
      var error = ""
      var count = -1
      var delivered = 0
      createRoot proc(disposeRoot: proc()) =
        let source = newHostFedDataSource(proc(loadId, pageSize: int) =
          probe.command("load " & $loadId & " " & $pageSize))
        let vm = newSessionTabStripVM(source, tabs = tsOpenedOnly)
        vm.load()
        let deadline = getMonoTime() + initDuration(seconds = 30)
        while getMonoTime() < deadline and vm.state.val == asLoading:
          let got = probe.messages
          while delivered < got.len:
            discard source.deliver(got[delivered])
            inc delivered
          sleep(50)
        state = vm.state.val
        error = vm.error.val
        count = vm.listedSessions.len
        vm.dispose()
        disposeRoot()
      check state == asError
      check "401" in error
      check count == 0

removeDir(workDir)
