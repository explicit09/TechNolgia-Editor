create table public.shorts (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    source_asset text not null,
    hook text not null,
    label text not null,
    duration numeric not null,
    evergreen_score int not null default 0,
    trending_score int not null default 0,
    platform_fit text[] not null default '{}',
    source_start numeric not null,
    source_end numeric not null,
    video_path text not null,
    thumbnail_path text not null,
    video_size bigint not null default 0,
    reasoning text not null default ''
);

create index shorts_created_at_desc on public.shorts (created_at desc);

-- RLS: anon clients can SELECT only. INSERT/UPDATE/DELETE go through the
-- service-role key from the Mac uploader, which bypasses RLS by design.
alter table public.shorts enable row level security;

create policy "anon read shorts"
on public.shorts for select
using (true);
