# lex-agent — lex-trail event kind constants
#
# Naming convention: "agent.<noun>.<verb>" (past tense)
# Effects: none.

fn decision_made() -> Str {
  "agent.decision.made"
}

fn goal_met() -> Str {
  "agent.goal.met"
}

fn budget_exhausted() -> Str {
  "agent.budget.exhausted"
}
