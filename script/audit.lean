import Lean

open Lean

def recheckModule (name : Name) : IO Unit := do
  let olean ← findOLean name
  let mut files := #[olean]
  for level in [OLeanLevel.server, .private] do
    let part := level.adjustFileName olean
    if ← part.pathExists then
      files := files.push part
  let parts ← readModuleDataParts files
  let some (first, _) := parts[0]?
    | throw (IO.userError s!"Could not read module {name}")
  let some (last, _) := parts.back?
    | throw (IO.userError s!"Could not read declarations for {name}")
  let env ← importModules first.imports {} (loadExts := false)
  let mut declarations : Std.HashMap Name ConstantInfo := {}
  for constant in last.constNames, info in last.constants do
    declarations := declarations.insert constant info
  discard <| env.toKernelEnv.replay declarations

def main : IO UInt32 := do
  initSearchPath (← findSysroot)
  -- Read kernel declarations without running initializers supplied by proof files.
  let env ← importModules #[{ module := `Audit }] {} (loadExts := false)
  let roots := #[`checkedCertificate, `Keisiki.invoke_lower]
  for root in roots do
    unless (env.checked.get.find? root).isSome do
      throw (IO.userError s!"Missing checked theorem {root}")
  let scan : CoreM (Array Name) := do
    let mut axioms : NameSet := {}
    for root in roots do
      for name in ← collectAxioms root do
        axioms := axioms.insert name
    return axioms.toArray.qsort Name.lt
  let (axioms, _) ← scan.toIO { fileName := "<audit>", fileMap := default } { env }
  let allowed := #[`propext, `Classical.choice, `Quot.sound]
  let unapproved := axioms.filter fun axiomName => !allowed.contains axiomName
  unless unapproved.isEmpty do
    throw (IO.userError s!"Proof depends on unapproved axioms: {unapproved.toList}")
  for name in [`GeneratedRuby, `VerificationClaim, `VerificationCertificate, `Audit] do
    recheckModule name
  IO.println (toJson (axioms.map toString)).compress
  return 0
