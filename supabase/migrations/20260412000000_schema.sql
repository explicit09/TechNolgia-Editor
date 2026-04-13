-- Dedicated schema for the iOS distribution app's tables. Keeps this product
-- isolated from other tables in the technologia-builder-network project.
-- The Supabase REST API must be configured to expose this schema:
--   config.toml: [api] schemas = ["public", "shorts_app"]
create schema if not exists shorts_app;
grant usage on schema shorts_app to anon, authenticated, service_role;
grant all on all tables in schema shorts_app to service_role;
grant select, update on all tables in schema shorts_app to anon;

-- Default privileges for tables CREATED IN FUTURE migrations within this schema
alter default privileges in schema shorts_app
    grant all on tables to service_role;
alter default privileges in schema shorts_app
    grant select, update on tables to anon;
alter default privileges in schema shorts_app
    grant insert on tables to anon;  -- specific tables (share_intents) need insert
