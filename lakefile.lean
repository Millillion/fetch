import Lake
open System Lake DSL

package fetch where
  version := v!"0.1.0"
  description := "A fetch-style HTTP client for Lean 4, built on Std.Http"
  keywords := #["http", "fetch", "client", "networking"]
  license := "MIT"
  testDriver := "FetchTest"

/-- The transport shim (`c/fetch_shim.c`), compiled with Lean's own C compiler:
no system compiler, libcurl or curl headers are needed to build. -/
target fetch_shim.o pkg : FilePath := do
  let oFile := pkg.buildDir / "c" / "fetch_shim.o"
  let srcJob ← inputTextFile <| pkg.dir / "c" / "fetch_shim.c"
  buildLeanO oFile srcJob #[] (#["-O2", "-DNDEBUG"] ++ if Platform.isWindows then #[] else #["-fPIC"])

extern_lib libfetchshim pkg := do
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "fetchshim") #[← fetch_shim.o.fetch]

@[default_target]
lean_lib Fetch

/-- The test suite (also used by Lasm's ecosystem checks). -/
lean_lib FetchTests

lean_exe FetchTest where
  root := `FetchTest
