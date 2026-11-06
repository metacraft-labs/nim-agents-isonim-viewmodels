## A `nim c -r` asked for one Agent Harbor fixture set runs a binary that
## embeds that set, even when the previous run asked for another.
##
## WHY.  `fixture_source.nim` chooses its set at compile time from the
## `AGENT_HARBOR_FIXTURES` environment variable.  Nim cannot see that input: a
## `nim c -r` whose command line, config files and sources are unchanged skips
## the compile and re-runs the old binary.  So after a run over one set,
## `AGENT_HARBOR_FIXTURES=synthetic just test` used to test the other one,
## and the in-binary guard ("the fixture set the build asked for is the one
## embedded") passed because it was compiled into the same stale binary.  The
## repo-root `config.nims` now keys the nimcache on the fixture inputs; its
## FIXTURE SETS paragraph has the details.
##
## WHAT THIS CHECKS.  `tests/probes/fixture_set_probe.nim`, which prints the
## set it embedded, is compiled and run with the SAME `nim c -r` command line
## three times, only the environment changing: a relabelled copy of the
## synthetic set (`fixtureSet` = `switch-probe`), then `synthetic`, then the
## copy again.  Each run must report the set it was asked for.  The first run
## is the control: it shows the probe can tell the two sets apart, so the
## second run's verdict is not vacuous.
##
## Cost: three compiles of the probe (about a minute on a cold cache).
##
## NO MOCKS: the real compiler, the real config files, the real fixture set.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

const
  SelfSource = currentSourcePath()
  CompilerAtBuild = getCurrentCompilerExe()
  ProbeRel = "tests/probes/fixture_set_probe.nim"
  SiblingSources = ["nim-agents", "nim-agent-harbor", "nim-acp",
                    "nim-everywhere", "isonim"]
    ## The `--path:` siblings the Justfile passes.

let root = SelfSource.parentDir.parentDir
let nimExe =
  if fileExists(CompilerAtBuild): CompilerAtBuild
  else: findExe("nim")

proc probeEnv(fixtures: string): StringTableRef =
  ## This process's environment with `AGENT_HARBOR_FIXTURES=<fixtures>`.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["AGENT_HARBOR_FIXTURES"] = fixtures

proc probeArgs(command: seq[string]; workDir: string): seq[string] =
  ## `nim <command>` of the probe, with the Justfile's paths.
  result = command & @["--hints:off", "--warnings:off", "--path:src"]
  for sibling in SiblingSources:
    result.add("--path:../" & sibling & "/src")
  result.add("-o:" & (workDir / "fixture_set_probe"))
  result.add(ProbeRel)

proc runNim(args: seq[string]; env: StringTableRef):
    tuple[output: string, code: int] =
  let p = startProcess(nimExe, workingDir = root, args = args, env = env,
                       options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()

proc probeRun(fixtures, workDir: string): tuple[output: string, code: int] =
  ## Compiles and runs the probe with `AGENT_HARBOR_FIXTURES=<fixtures>`.
  ## The command line is identical on every call; only the environment moves.
  runNim(probeArgs(@["c", "-r"], workDir), probeEnv(fixtures))

proc removeProbeCache(fixtures, workDir: string) =
  ## Removes the nimcache a probe run with `fixtures` used, as `nim dump`
  ## reports it.  A fixture directory under a fresh temporary path gets a
  ## nimcache of its own (config.nims keys the cache on the variable), so
  ## without this every run would leave one behind.  Only a directory inside
  ## the checkout's `.nimcache` is ever removed.
  let dump = runNim(probeArgs(@["dump", "--dump.format:json"], workDir),
                    probeEnv(fixtures))
  let cachesRoot = root / ".nimcache"
  for line in dump.output.splitLines():
    if line.startsWith("{"):
      let cache = parseJson(line){"nimcache"}.getStr
      if cache.len > cachesRoot.len and cache.startsWith(cachesRoot & DirSep):
        removeDir(cache)
      else:
        echo "not removing the probe nimcache ", cache,
          ": it is not inside ", cachesRoot
      return
  echo "could not find the probe nimcache to remove:\n", dump.output

proc embeddedSet(run: tuple[output: string, code: int]): string =
  ## The set the probe reported; "" (and the output echoed) when it did not.
  if run.code == 0:
    for line in run.output.splitLines():
      if line.startsWith("fixture-set="):
        return line["fixture-set=".len .. ^1]
  echo run.output
  ""

suite "a nim c -r asked for one fixture set tests that set":
  test "switching AGENT_HARBOR_FIXTURES between runs rebuilds the binary":
    require nimExe.len > 0
    let workDir = getTempDir() / ("fixture-set-switch-" & $getCurrentProcessId())
    removeDir(workDir)
    createDir(workDir)
    defer: removeDir(workDir)

    # A second set the probe can tell apart from the synthetic one: the
    # synthetic files, with the manifest's label changed.
    let alternative = workDir / "switch-probe-fixtures"
    defer: removeProbeCache(alternative, workDir)
    copyDir(root / "fixtures" / "agent-harbor", alternative)
    let manifestPath = alternative / "manifest.json"
    var manifest = parseFile(manifestPath)
    manifest["fixtureSet"] = %"switch-probe"
    writeFile(manifestPath, $manifest)

    # Control: the relabelled set is the one embedded when asked for.
    check embeddedSet(probeRun(alternative, workDir)) == "switch-probe"
    # The issue: the same command line asked for the synthetic set used to
    # re-run the binary that embeds the relabelled one.
    check embeddedSet(probeRun("synthetic", workDir)) == "synthetic"
    # And back again, so a cache kept per set does not serve a stale binary
    # either.
    check embeddedSet(probeRun(alternative, workDir)) == "switch-probe"
