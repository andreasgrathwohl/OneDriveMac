-- Berichts-Datenbank für OneDrive Opener (Supabase).
-- Die App nutzt den öffentlichen "publishable key": sie darf Berichte nur EINFÜGEN und Anfragen nur LESEN.
-- Berichte lesen nur der Projekt-Eigentümer (Dashboard / Service-Rolle).

create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  install_id  uuid not null,
  app_version text,
  os_version  text,
  kind        text not null,            -- start | error | learned | diagnostics
  message     text,
  payload     jsonb
);

create table if not exists public.requests (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  install_id  uuid,                      -- null = alle Geräte
  kind        text not null              -- diagnostics | update
);

alter table public.reports  enable row level security;
alter table public.requests enable row level security;

-- Nicht jedes Projekt gibt neue Tabellen automatisch für die API frei.
grant insert on public.reports  to anon;
grant select on public.requests to anon;

drop policy if exists "app darf berichte einfuegen" on public.reports;
create policy "app darf berichte einfuegen" on public.reports
  for insert to anon
  with check (length(coalesce(message, '')) < 10000 and coalesce(pg_column_size(payload), 0) < 1000000);

drop policy if exists "app darf anfragen lesen" on public.requests;
create policy "app darf anfragen lesen" on public.requests
  for select to anon using (true);

-- Beispiel: Diagnose von allen Geräten anfordern
-- insert into public.requests (kind) values ('diagnostics');
