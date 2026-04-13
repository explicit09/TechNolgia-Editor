create table shorts_app.share_intents (
    id uuid primary key default gen_random_uuid(),
    short_id uuid not null references shorts_app.shorts(id) on delete cascade,
    platform text not null check (platform in ('youtube_shorts', 'tiktok', 'instagram_reels', 'twitter', 'linkedin')),
    triggered_at timestamptz not null default now()
);

create index share_intents_short_id on shorts_app.share_intents (short_id);
create index share_intents_triggered_at_desc on shorts_app.share_intents (triggered_at desc);

alter table shorts_app.share_intents enable row level security;

create policy "anon read share intents"
on shorts_app.share_intents for select
using (true);

create policy "anon insert share intents"
on shorts_app.share_intents for insert
with check (true);
