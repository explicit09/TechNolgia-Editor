// regenerate-caption: re-writes a caption for a specific (short, platform) using Claude.
// Called from iOS app. Anthropic API key is stored as a Supabase secret; never exposed to client.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.43.0";

function requireEnv(name: string): string {
    const value = Deno.env.get(name);
    if (!value) {
        throw new Error(`Missing required environment variable: ${name}. Set it via: supabase secrets set ${name}=...`);
    }
    return value;
}

const SUPABASE_URL = requireEnv("SUPABASE_URL");
const SERVICE_KEY = requireEnv("SUPABASE_SERVICE_ROLE_KEY");
const ANTHROPIC_API_KEY = requireEnv("ANTHROPIC_API_KEY");

interface RegenerateRequest {
    short_id: string;
    platform: "youtube_shorts" | "tiktok" | "instagram_reels" | "twitter" | "linkedin";
    tone?: "default" | "spicier" | "more_professional";
}

const PLATFORM_INSTRUCTIONS: Record<string, string> = {
    youtube_shorts: "A YouTube Shorts video. Title ≤100 chars, description up to 500 words, 3-5 relevant hashtags. Title should be curiosity-driving.",
    tiktok: "A TikTok video. Caption body up to 150 words, 5-10 inline hashtags, casual conversational tone.",
    instagram_reels: "An Instagram Reel. Caption body up to 150 words with line breaks, 10-15 hashtags at the very end, lifestyle tone.",
    twitter: "A Twitter/X post. Keep the body under 240 chars to leave room for hashtags. 1-3 hashtags max. Direct, punchy.",
    linkedin: "A LinkedIn post. 2-4 paragraphs, 200-400 words, professional but human. 3-5 hashtags at the end.",
};

serve(async (req) => {
    if (req.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
    }

    const body = (await req.json()) as RegenerateRequest;
    if (!body.short_id || !body.platform) {
        return new Response(JSON.stringify({ error: "Missing short_id or platform" }), {
            status: 400,
            headers: { "content-type": "application/json" },
        });
    }

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

    const { data: shortRow, error: shortErr } = await supabase
        .schema("shorts_app").from("shorts")
        .select("hook, label, reasoning, duration")
        .eq("id", body.short_id)
        .single();

    if (shortErr || !shortRow) {
        return new Response(JSON.stringify({ error: "Short not found" }), {
            status: 404,
            headers: { "content-type": "application/json" },
        });
    }

    const toneHint = body.tone === "spicier"
        ? "Use a more provocative, controversial angle. Make viewers argue in the comments."
        : body.tone === "more_professional"
        ? "Use a measured, authoritative tone. Avoid slang."
        : "Match the natural tone of the original moment.";

    const prompt = `You are writing a social media caption for a short-form video clip.

Platform: ${body.platform}
Platform rules: ${PLATFORM_INSTRUCTIONS[body.platform]}
Tone: ${toneHint}

The clip's hook (the viral moment): "${shortRow.hook}"
Why it's viral: ${shortRow.reasoning}
Duration: ${shortRow.duration} seconds

Return ONLY a JSON object with this exact shape (no prose, no code fence):
{
  "title": "Title string or null if platform doesn't use titles",
  "body": "Main caption text",
  "hashtags": ["hashtag1", "hashtag2"]
}

Include the # prefix in each hashtag string.`;

    const claudeRes = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
            "content-type": "application/json",
            "x-api-key": ANTHROPIC_API_KEY,
            "anthropic-version": "2023-06-01",
        },
        body: JSON.stringify({
            model: "claude-sonnet-4-6",
            max_tokens: 2048,
            messages: [{ role: "user", content: prompt }],
        }),
    });

    if (!claudeRes.ok) {
        const errText = await claudeRes.text();
        return new Response(JSON.stringify({ error: "Claude API error", detail: errText }), {
            status: 502,
            headers: { "content-type": "application/json" },
        });
    }

    const claudeData = await claudeRes.json();
    const rawText = claudeData.content?.[0]?.text ?? "";

    const jsonMatch = rawText.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
        return new Response(JSON.stringify({ error: "Could not parse Claude response", raw: rawText }), {
            status: 500,
            headers: { "content-type": "application/json" },
        });
    }

    let parsed: { title: string | null; body: string; hashtags: string[] };
    try {
        parsed = JSON.parse(jsonMatch[0]);
    } catch (parseError) {
        const message = parseError instanceof Error ? parseError.message : String(parseError);
        return new Response(JSON.stringify({
            error: "Claude returned invalid JSON",
            detail: message,
            raw: rawText,
        }), {
            status: 500,
            headers: { "content-type": "application/json" },
        });
    }

    const { error: updateErr } = await supabase
        .schema("shorts_app").from("captions")
        .upsert({
            short_id: body.short_id,
            platform: body.platform,
            title: parsed.title,
            body: parsed.body,
            hashtags: parsed.hashtags,
            last_edited_by: "claude_regen",
        }, { onConflict: "short_id,platform" });

    if (updateErr) {
        return new Response(JSON.stringify({ error: "Update failed", detail: updateErr.message }), {
            status: 500,
            headers: { "content-type": "application/json" },
        });
    }

    return new Response(JSON.stringify(parsed), {
        status: 200,
        headers: { "content-type": "application/json" },
    });
});
