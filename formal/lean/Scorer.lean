import Std

/-
An executable Levenshtein specification and an independently implemented rolling row.
The specification is intentionally slow: it states the three permitted edit choices.
The rolling row caches suffix distances, scanning from right to left. Production scans
prefixes from left to right; differential tests connect those implementations to this oracle.
-/
namespace Hearsay

def distance [DecidableEq α] : List α → List α → Nat
  | [], ys => ys.length
  | xs, [] => xs.length
  | x :: xs, y :: ys =>
      min (distance xs (y :: ys) + 1)
        (min (distance (x :: xs) ys + 1) (distance xs ys + if x = y then 0 else 1))
termination_by xs ys => xs.length + ys.length
decreasing_by all_goals simp_wf <;> omega

def referenceRow [DecidableEq α] (xs : List α) : List α → List Nat
  | [] => [distance xs []]
  | y :: ys => distance xs (y :: ys) :: referenceRow xs ys

def initialRow : List α → List Nat
  | [] => [0]
  | _ :: ys => (ys.length + 1) :: initialRow ys

def nextRow [DecidableEq α] (x : α) : List α → List Nat → List Nat
  | [], previous => [previous.headD 0 + 1]
  | y :: ys, previous =>
      let next := nextRow x ys previous.tail
      min (previous.headD 0 + 1)
        (min (next.headD 0 + 1) (previous.tail.headD 0 + if x = y then 0 else 1)) :: next

def rows [DecidableEq α] : List α → List α → List Nat
  | [], ys => initialRow ys
  | x :: xs, ys => nextRow x ys (rows xs ys)

def rowDistance [DecidableEq α] (xs ys : List α) : Nat := (rows xs ys).headD 0

theorem referenceRow_head [DecidableEq α] (xs ys : List α) :
    (referenceRow xs ys).headD 0 = distance xs ys := by
  cases ys <;> simp [referenceRow]

theorem initialRow_correct [DecidableEq α] (ys : List α) :
    initialRow ys = referenceRow ([] : List α) ys := by
  induction ys with
  | nil => simp [initialRow, referenceRow, distance]
  | cons y ys ih => simp [initialRow, referenceRow, distance, ih]

theorem nextRow_correct [DecidableEq α] (x : α) (xs ys : List α) :
    nextRow x ys (referenceRow xs ys) = referenceRow (x :: xs) ys := by
  induction ys with
  | nil => cases xs <;> simp [nextRow, referenceRow, distance]
  | cons y ys ih =>
      simp only [nextRow, referenceRow, List.headD_cons, List.tail_cons, ih, referenceRow_head, distance]

theorem rows_correct [DecidableEq α] (xs ys : List α) :
    rows xs ys = referenceRow xs ys := by
  induction xs with
  | nil => exact initialRow_correct ys
  | cons x xs ih => simp [rows, ih, nextRow_correct]

theorem rowDistance_correct [DecidableEq α] (xs ys : List α) :
    rowDistance xs ys = distance xs ys := by
  unfold rowDistance
  rw [rows_correct, referenceRow_head]

theorem distance_self [DecidableEq α] (xs : List α) : distance xs xs = 0 := by
  induction xs with
  | nil => simp [distance]
  | cons x xs ih => simp [distance, ih]

theorem distance_zero_iff [DecidableEq α] (xs ys : List α) :
    distance xs ys = 0 ↔ xs = ys := by
  constructor
  · intro h
    induction xs generalizing ys with
    | nil => cases ys <;> simp_all [distance]
    | cons x xs ih =>
        cases ys with
        | nil => simp [distance] at h
        | cons y ys =>
            by_cases equal : x = y
            · subst y
              have tailZero : distance xs ys = 0 := by
                simp only [distance] at h
                omega
              exact congrArg (List.cons x) (ih ys tailZero)
            · simp only [distance, if_neg equal] at h
              omega
  · intro h
    subst ys
    exact distance_self xs

theorem distance_symmetric [DecidableEq α] (xs ys : List α) :
    distance xs ys = distance ys xs := by
  induction xs generalizing ys with
  | nil => cases ys <;> simp [distance]
  | cons x xs ih =>
      induction ys with
      | nil => simp [distance]
      | cons y ys ihy =>
          simp only [distance]
          rw [ih (y :: ys), ih ys, ihy]
          simp only [eq_comm]
          omega

theorem distance_length_bounds [DecidableEq α] (xs ys : List α) :
    xs.length - ys.length ≤ distance xs ys ∧
    ys.length - xs.length ≤ distance xs ys ∧
    distance xs ys ≤ max xs.length ys.length := by
  induction xs generalizing ys with
  | nil => cases ys <;> simp [distance]
  | cons x xs ih =>
      induction ys with
      | nil => simp [distance]
      | cons y ys ihy =>
          have h₁ := ih (y :: ys)
          have h₂ := ih ys
          simp only [List.length_cons] at ihy
          simp only [List.length_cons] at h₁ ⊢
          simp only [distance]
          split <;> omega

theorem rowDistance_self [DecidableEq α] (xs : List α) : rowDistance xs xs = 0 := by
  rw [rowDistance_correct, distance_self]

theorem rowDistance_symmetric [DecidableEq α] (xs ys : List α) :
    rowDistance xs ys = rowDistance ys xs := by
  simp only [rowDistance_correct, distance_symmetric]

-- Audit the axioms of the proof that connects the two independent implementations.
#print axioms rowDistance_correct
#print axioms distance_self
#print axioms distance_zero_iff
#print axioms distance_symmetric
#print axioms distance_length_bounds
end Hearsay
