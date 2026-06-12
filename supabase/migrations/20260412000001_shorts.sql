create table shorts_app.shorts (
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
    reasoning text not null default '',
    distribution_score int not null default 0,
    posting_priority text not null default 'review',
    score_warnings text[] not null default '{}',
    best_platforms text[] not null default '{}',
    score_breakdown jsonb not null default '{}'::jsonb,
    pipeline_grade jsonb not null default '{}'::jsonb
);

create index shorts_created_at_desc on shorts_app.shorts (created_at desc);
create index shorts_distribution_score_desc on shorts_app.shorts (distribution_score desc);

-- RLS: anon clients can SELECT only. INSERT/UPDATE/DELETE go through the
-- service-role key from the Mac uploader, which bypasses RLS by design.
alter table shorts_app.shorts enable row level security;

create policy "anon read shorts"
on shorts_app.shorts for select
using (true);
