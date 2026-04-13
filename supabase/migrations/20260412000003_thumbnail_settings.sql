create table public.thumbnail_settings (
    short_id uuid primary key references public.shorts(id) on delete cascade,
    label_text text not null,
    label_color text not null default '#C9A028' check (label_color in ('#C9A028', '#070D17', '#FFFFFF', '#E91E63', '#00C853')),
    label_position text not null default 'bottom-center' check (label_position in (
        'top-left', 'top-center', 'top-right',
        'center-left', 'center', 'center-right',
        'bottom-left', 'bottom-center', 'bottom-right'
    )),
    frame_index int not null default 0 check (frame_index between 0 and 9),
    updated_at timestamptz not null default now()
);

-- RLS: anon clients can SELECT + UPDATE. Rows are INSERTED by the Mac
-- uploader via the service-role key, which bypasses RLS by design.
alter table public.thumbnail_settings enable row level security;

create policy "anon read thumbnail settings"
on public.thumbnail_settings for select
using (true);

-- v1: no user model; all anon clients can update any row. Acceptable for
-- a closed 2-user pilot. Tighten to per-user ownership if scope broadens.
create policy "anon update thumbnail settings"
on public.thumbnail_settings for update
using (true)
with check (true);

create or replace function public.thumbnail_settings_touch_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

create trigger thumbnail_settings_touch_updated_at
before update on public.thumbnail_settings
for each row execute function public.thumbnail_settings_touch_updated_at();
