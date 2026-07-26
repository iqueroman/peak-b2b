-- =============================================================================
--  02 — Load the raw file
--
--  \copy runs client-side, so the CSV is read with the permissions of whoever
--  ran `make load` and never has to be mounted into the database container.
--
--  TRUNCATE first: the pipeline is a rebuild, not an accumulation. Running it
--  twice must produce identical output (issue 07), and the cheapest way to
--  guarantee that is to have no run-to-run state to get out of step.
-- =============================================================================

TRUNCATE landing.contact_csv RESTART IDENTITY;

\copy landing.contact_csv (contact_id, first_name, last_name, email, linkedin_url, title, seniority, company_name, company_domain, employee_count, industry, country, source, date_added, last_contacted_date, last_contacted_channel, last_sending_domain, last_campaign, last_outcome, hubspot_lifecycle_stage, notes) FROM 'noble-outbound-contacts.csv' WITH (FORMAT csv, HEADER true)

SELECT count(*) AS landed_rows FROM landing.contact_csv;
