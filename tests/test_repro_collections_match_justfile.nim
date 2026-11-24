## `repro test` and `just test` run the same suites: every test module the
## `Justfile` compiles or runs is declared in `repro.nim`, and the reverse.
##
## WHY.  `repro.nim` declares its tests as lists of files (`viewmodelTests`,
## `viewmodelJsBuildStems`, `viewmodelJsTestStems`), one BUILD and one EXECUTE
## edge per entry.  The `Justfile` names the same modules again, one line each,
## in `build-native`, `build-js`, `test-native` and `test-js`.  Two lists of
## the same thing drift: from the fleet viewmodel's commit until this test
## existed, every suite was added to the `Justfile` only, and `repro test` ran
## three of the seventeen native suites and none of the JS ones while
## reporting success.  The rule both lists answer to is codetracer-pm's
## `spec/Repo-Requirements.md` §2.8.1: `just test` and `repro test` run the
## same set of tests, and `just build` and `repro build` build the same
## modules.
##
## WHAT THIS CHECKS.  Both files are read at compile time (`staticRead`), so
## the binary compares the lists as they were when it was built; the repro
## BUILD edge names both files as inputs, so editing either rebuilds it.
##   1. CONTROL.  Each recipe and each list is found and is not empty, so a
##      renamed recipe or constant fails here rather than comparing two empty
##      sets and passing.
##   2. NATIVE.  `test-native` and `build-native` name exactly the modules
##      of `viewmodelTests`.
##   3. JS.  `test-js` names exactly `viewmodelJsTestStems`, and `build-js`
##      exactly `viewmodelJsBuildStems`.
##   4. COVERAGE.  Every `tests/test_*.nim` (the directory as it was at
##      compile time) is in `viewmodelTests`, so a new suite added to neither
##      file is caught too.
##
## NO MOCKS: the real `Justfile`, `repro.nim` and `tests/` directory.
##
## Native only: the check concerns the two files, not a backend, so one
## target is enough.

import std/[algorithm, os, sequtils, strutils, unittest]

const
  RepoRoot = currentSourcePath().parentDir.parentDir
  JustfileText = staticRead(RepoRoot / "Justfile")
  ReproNimText = staticRead(RepoRoot / "repro.nim")

proc testModulesOnDisk(): seq[string] {.compileTime.} =
  ## `tests/test_*.nim`, repo-relative, sorted.
  for kind, path in walkDir(RepoRoot / "tests", relative = true):
    if kind == pcFile and path.startsWith("test_") and path.endsWith(".nim"):
      result.add("tests/" & path)
  result.sort()

const TestModulesOnDisk = testModulesOnDisk()

proc recipeModules(justfile, recipe: string): seq[string] =
  ## The `tests/*.nim` arguments of every line of `recipe`'s body, sorted.
  ## A body is the indented lines that follow `<recipe>:`; it ends at the
  ## first line that is neither indented nor empty.
  var inRecipe = false
  for line in justfile.splitLines():
    if not inRecipe:
      if line.startsWith(recipe & ":"):
        inRecipe = true
      continue
    if line.len > 0 and line[0] notin {' ', '\t'}:
      break
    for word in line.splitWhitespace():
      if word.startsWith("tests/") and word.endsWith(".nim"):
        result.add(word)
  result.sort()

proc constStrings(reproNim, name: string): seq[string] =
  ## The string literals of `const <name> = @[ ... ]` in `repro.nim`, in
  ## order.  Empty when the constant is absent.
  let start = reproNim.find("const " & name & " = @[")
  if start < 0:
    return
  let close = reproNim.find("]", start)
  if close < 0:
    return
  var i = reproNim.find("@[", start) + 2
  while i < close:
    if reproNim[i] == '"':
      let stop = reproNim.find('"', i + 1)
      result.add(reproNim[i + 1 ..< stop])
      i = stop + 1
    else:
      inc i

proc stemsToModules(stems: seq[string]): seq[string] =
  result = stems.mapIt("tests/" & it & ".nim")
  result.sort()

let
  reproNative = sorted(constStrings(ReproNimText, "viewmodelTests"))
  reproJsBuild = stemsToModules(
    constStrings(ReproNimText, "viewmodelJsBuildStems"))
  reproJsTest = stemsToModules(
    constStrings(ReproNimText, "viewmodelJsTestStems"))

proc missingFrom(have, want: seq[string]): seq[string] =
  want.filterIt(it notin have)

suite "repro.nim declares the suites the Justfile runs":
  test "control: every recipe and every list is found and not empty":
    for recipe in ["build-native", "test-native", "build-js", "test-js"]:
      checkpoint "recipe " & recipe
      check recipeModules(JustfileText, recipe).len > 0
    check reproNative.len > 0
    check reproJsBuild.len > 0
    check reproJsTest.len > 0
    check TestModulesOnDisk.len > 0

  test "test-native and build-native name exactly viewmodelTests":
    for recipe in ["test-native", "build-native"]:
      let just = recipeModules(JustfileText, recipe)
      checkpoint recipe & " but not repro.nim: " &
        $missingFrom(reproNative, just)
      checkpoint "repro.nim but not " & recipe & ": " &
        $missingFrom(just, reproNative)
      check just == reproNative

  test "test-js names exactly viewmodelJsTestStems":
    let just = recipeModules(JustfileText, "test-js")
    checkpoint "test-js but not repro.nim: " & $missingFrom(reproJsTest, just)
    checkpoint "repro.nim but not test-js: " & $missingFrom(just, reproJsTest)
    check just == reproJsTest

  test "build-js names exactly viewmodelJsBuildStems":
    let just = recipeModules(JustfileText, "build-js")
    checkpoint "build-js but not repro.nim: " &
      $missingFrom(reproJsBuild, just)
    checkpoint "repro.nim but not build-js: " &
      $missingFrom(just, reproJsBuild)
    check just == reproJsBuild

  test "every tests/test_*.nim is in viewmodelTests":
    checkpoint "not declared: " & $missingFrom(reproNative, TestModulesOnDisk)
    check missingFrom(reproNative, TestModulesOnDisk).len == 0
