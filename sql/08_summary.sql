-- =============================================================================
--  08 — The reconciliation summary
--
--  Printed at the end of every run. The only number that matters is the last
--  one: residual must be zero. Everything above it is the working.
-- =============================================================================

\pset border 2
\pset footer off

\echo ''
\echo '=== Run configuration ==='
SELECT key, value FROM config.setting ORDER BY key;

\echo ''
\echo '=== Identity resolution (issue 03) ==='
SELECT 'rows in CSV'                    AS step, (SELECT rows_in FROM reconciliation)       AS n
UNION ALL SELECT 'absorbed by dedup (R1 email, R2 linkedin)', (SELECT rows_absorbed FROM reconciliation)
UNION ALL SELECT 'persons resolved',    (SELECT persons FROM reconciliation)
UNION ALL SELECT 'held: identity needs review', (SELECT count(*) FROM person WHERE needs_review)
UNION ALL SELECT 'quarantined (unkeyable)', (SELECT quarantined FROM reconciliation)
UNION ALL SELECT 'companies resolved',  (SELECT count(*) FROM company)
UNION ALL SELECT 'independents (no company)', (SELECT count(*) FROM person WHERE is_independent);

\echo ''
\echo '=== Event log (issue 04) — reconstructed from the collapsed columns ==='
SELECT event_type, count(*) AS n
  FROM contact_event GROUP BY 1 ORDER BY 2 DESC;

\echo ''
\echo '=== Sending-domain lock (issue 04 §2) — assigns, never rejects ==='
SELECT cl.lock_basis, count(*) AS companies, sum(pc.n) AS people
  FROM company_lock cl
  JOIN LATERAL (SELECT count(*) AS n FROM person p WHERE p.company_id = cl.company_id) pc ON true
 GROUP BY 1 ORDER BY 1;

\echo ''
\echo '=== Rejection ledger (issue 04 §7) — first match wins, most permanent first ==='
SELECT r.precedence AS "#", l.rule_name AS rule, r.scope, count(*) AS rejected
  FROM eligibility_ledger l
  JOIN eligibility_rule r USING (rule_name)
 WHERE l.decision = 'rejected'
 GROUP BY 1, 2, 3
 ORDER BY 1;

\echo ''
\echo '=== Eligible ==='
SELECT eligible_basis AS basis,
       array_to_string(channels, '+') AS channels,
       count(*) AS n
  FROM eligibility_ledger
 WHERE decision = 'eligible'
 GROUP BY 1, 2 ORDER BY 3 DESC;

SELECT sending_domain, count(*) AS n
  FROM eligibility_ledger
 WHERE decision = 'eligible'
 GROUP BY 1 ORDER BY 1;

\echo ''
\echo '=== Reconciliation ==='
SELECT rows_in,
       rows_absorbed,
       persons,
       eligible,
       rejected,
       quarantined,
       -- The claim: nothing is lost between the raw file and the two artifacts.
       rows_in - (eligible + rejected + quarantined + rows_absorbed) AS residual
  FROM reconciliation;

DO $$
DECLARE
    r record;
BEGIN
    SELECT * INTO r FROM reconciliation;
    IF r.rows_in <> r.eligible + r.rejected + r.quarantined + r.rows_absorbed THEN
        RAISE EXCEPTION 'reconciliation failed: % rows in, % accounted for',
              r.rows_in, r.eligible + r.rejected + r.quarantined + r.rows_absorbed;
    END IF;
    RAISE NOTICE 'reconciled: % rows = % eligible + % rejected + % quarantined + % absorbed by dedup',
          r.rows_in, r.eligible, r.rejected, r.quarantined, r.rows_absorbed;
END $$;
