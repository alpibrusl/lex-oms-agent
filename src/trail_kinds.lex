# lex-agent — lex-trail event kind constants
#
# Naming convention: "agent.<noun>.<verb>" (past tense)
# Effects: none.
# Logged BEFORE tool dispatch — proves what the agent decided before the OMS acted.

fn decision_intent() -> Str {
  "agent.decision.intent"
}

# Logged AFTER tool dispatch — records the outcome. Parent = decision_intent event id.
fn decision_made() -> Str {
  "agent.decision.made"
}

fn goal_met() -> Str {
  "agent.goal.met"
}

fn budget_exhausted() -> Str {
  "agent.budget.exhausted"
}

