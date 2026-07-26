-- tests/40_reconciliation_test.sql
--
-- The claim the whole component rests on: nothing is lost between the raw file
-- and the two output artifacts. A pipeline that says "724 people are eligible"
-- is unverifiable; one that accounts for all 2,154 rows is arguable.

-- Row grain: every input row is either represented by a person or was absorbed
-- into one by dedup. Quarantine is a third bucket and must be reported even
-- when it is empty.
SELECT test.expect('reconcile', 'rows in = persons + absorbed + quarantined', 0,
                   (SELECT rows_in - (persons + rows_absorbed + quarantined)
                      FROM reconciliation));

-- Person grain: every person is eligible, rejected, or quarantined. No
-- residual — this is the assertion the summary line prints.
SELECT test.expect('reconcile', 'persons = eligible + rejected', 0,
                   (SELECT persons - (eligible + rejected) FROM reconciliation));

SELECT test.expect('reconcile', 'rows_in', 2154, (SELECT rows_in FROM reconciliation));
SELECT test.expect('reconcile', 'persons', 2114, (SELECT persons FROM reconciliation));
SELECT test.expect('reconcile', 'eligible', 723, (SELECT eligible FROM reconciliation));
SELECT test.expect('reconcile', 'rejected', 1391, (SELECT rejected FROM reconciliation));
SELECT test.expect('reconcile', 'quarantined', 0, (SELECT quarantined FROM reconciliation),
                   '03: linkedin_url is present on 100% of rows, so no row is unkeyable');

-- Every rejection carries a rule that exists in the rule table, and evidence.
-- A rejection ledger without evidence is just a smaller unverifiable number.
SELECT test.expect('reconcile', 'every rejection names a declared rule', 0,
                   (SELECT count(*) FROM eligibility_ledger l
                     LEFT JOIN eligibility_rule r USING (rule_name)
                    WHERE l.decision = 'rejected' AND r.rule_name IS NULL));

SELECT test.expect('reconcile', 'every rejection carries evidence', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'rejected'
                       AND (evidence IS NULL OR evidence = '{}'::jsonb)));

-- Eligible rows must be actionable: a channel and a sending domain, or the
-- list cannot be handed to Instantly or HeyReach.
SELECT test.expect('reconcile', 'every eligible person has a channel', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible'
                       AND coalesce(array_length(channels, 1), 0) = 0));

SELECT test.expect('reconcile', 'every eligible person has a sending domain', 0,
                   (SELECT count(*) FROM eligibility_ledger
                     WHERE decision = 'eligible' AND sending_domain IS NULL));

-- 04: LinkedIn is not a domain for this purpose. Someone with no usable email
-- is still reachable, on LinkedIn only.
SELECT test.expect('reconcile', 'eligible with no usable email are linkedin-only', 0,
                   (SELECT count(*) FROM eligibility_ledger l
                     JOIN person p USING (person_id)
                    WHERE l.decision = 'eligible'
                      AND p.primary_email IS NULL
                      AND 'email' = ANY (l.channels)));

-- The event log is append-only and is the only truth. If a state column ever
-- appears on person or company, this fails.
SELECT test.expect('reconcile', 'no stored state column anywhere', 0,
                   (SELECT count(*) FROM information_schema.columns
                     WHERE table_schema = 'public'
                       AND table_name IN ('person', 'company')
                       AND column_name IN ('state', 'status', 'lifecycle_stage')));

-- 04: the CSV's 781 contacted rows are reconstructed as synthetic events. The
-- migration from lossy collapse to event log *is* the demonstration.
SELECT test.expect('reconcile', 'csv_backfill contact events', 781,
                   (SELECT count(DISTINCT source_row_id) FROM contact_event
                     WHERE source = 'csv_backfill' AND event_type = 'sent'));
