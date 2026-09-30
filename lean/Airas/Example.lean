import Mathlib.Tactic

/-- Placeholder showing the shape of a claim's declaration. A `lean` claim
names the module (`Airas.Example`), the declaration (`airas_example`) and
its statement as `#check @airas_example` prints it. Replace with the real
theorems. -/
theorem airas_example (n : ℕ) : n + 0 = n := by
  simp
