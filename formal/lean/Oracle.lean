import Lean
import Scorer

open Lean

def tokens (json : Json) (key : String) : Except String (List String) := do
  let value ← json.getObjVal? key
  let values ← value.getArr?
  values.toList.mapM Json.getStr?

def answer (line : String) : Except String Json := do
  let json ← Json.parse line
  let reference ← tokens json "referenceTokens"
  let hypothesis ← tokens json "hypothesisTokens"
  pure <| toJson (Hearsay.rowDistance reference hypothesis)

def main : IO Unit := do
  let input ← IO.getStdin
  let output ← IO.getStdout
  repeat
    let line ← input.getLine
    if line.isEmpty then break
    match answer line with
    | .ok value => output.putStrLn value.compress
    | .error message => throw <| IO.userError message
