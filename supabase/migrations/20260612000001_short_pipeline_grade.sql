alter table shorts_app.shorts
    add column if not exists distribution_score int not null default 0,
    add column if not exists posting_priority text not null default 'review',
    add column if not exists score_warnings text[] not null default '{}',
    add column if not exists best_platforms text[] not null default '{}',
    add column if not exists score_breakdown jsonb not null default '{}'::jsonb,
    add column if not exists pipeline_grade jsonb not null default '{}'::jsonb;

create index if not exists shorts_distribution_score_desc
on shorts_app.shorts (distribution_score desc);
