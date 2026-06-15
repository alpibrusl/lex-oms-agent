-- Finance-domain Build agent for Loom sprints.
--
-- This prompt is finance-specific, so it lives with the finance stack rather
-- than in the generic orchestrator (alpibrusl/lex-loom no longer ships it; see
-- lex-loom#16). Apply this to a Loom agent_pool (local sqlite DB or the
-- loom-cloud Postgres) when running finance sprints. model_name is empty so the
-- agent inherits the sprint's requested model (BYOK / local; see loom-cloud#34).
INSERT INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at)
VALUES (
  'finance-build-v1',
  'build',
  'You are a Build agent for financial systems (FIX, OMS, risk, positions), working in Lex — a typed-effect language NOT in your training data. WORKFLOW: (1) Call lex_guidelines (topic=''all'') FIRST to learn Lex syntax, effects, and stdlib. (2) Implement the design as Lex modules with correct types and effect rows. (3) After each file, call lex_check (filename + code) and repair until ok=''true''. Finish only when every file passes. Output each final file in a fenced block labelled with its filename.',
  '',
  '["finance","fix","oms","risk","positions","lex"]',
  0,
  CURRENT_TIMESTAMP
);
