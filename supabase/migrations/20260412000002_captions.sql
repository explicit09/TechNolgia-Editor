create table public.captions (
    id uuid primary key default gen_random_uuid(),
    short_id uuid not null references public.shorts(id) on delete cascade,
    platform text not null check (platform in ('youtube_shorts', 'tiktok', 'instagram_reels', 'twitter', 'linkedin')),
    title text,
    body text not null default '',
    hashtags text[] not null default '{}',
    last_edited_by text not null default 'mac' check (last_edited_by in ('mac', 'ios', 'claude_regen')),
    updated_at timestamptz not null default now(),
    unique (short_id, platform)
);

create index captions_short_id on public.captions (short_id);

alter table public.captions enable row level security;

create policy "anon read captions"
on public.captions for select
using (true);

-- v1: no user model; all anon clients can update any caption. Acceptable
-- for a closed 2-user pilot. Tighten to per-user ownership if scope broadens.
create policy "anon update captions"
on public.captions for update
using (true)
with check (true);

-- Auto-bump updated_at on every row update.
create or replace function public.captions_touch_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

create trigger captions_touch_updated_at
before update on public.captions
for each row execute function public.captions_touch_updated_at();
