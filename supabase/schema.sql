-- HAWME Production SQL Schema & Seed Data
-- Run this in your Supabase SQL Editor

-- 1. Users Table
CREATE TABLE IF NOT EXISTS public.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    username TEXT UNIQUE NOT NULL,
    tiktok_username TEXT NOT NULL,
    category TEXT NOT NULL,
    follower_range TEXT NOT NULL,
    role TEXT DEFAULT 'creator',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Campaigns Table
CREATE TABLE IF NOT EXISTS public.campaigns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    brand TEXT NOT NULL,
    verified BOOLEAN DEFAULT TRUE,
    type TEXT NOT NULL CHECK (type IN ('PROMOTION', 'CHALLENGE')),
    reward TEXT NOT NULL,
    amount_num NUMERIC(12, 2) NOT NULL,
    requirements TEXT NOT NULL,
    deadline TEXT NOT NULL,
    slots TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    rules JSONB,
    image_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Applications Table
CREATE TABLE IF NOT EXISTS public.applications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID REFERENCES public.campaigns(id) ON DELETE CASCADE,
    campaign_title TEXT NOT NULL,
    creator_uid TEXT NOT NULL,
    video_idea TEXT,
    evidence_url TEXT,
    status TEXT DEFAULT 'Awaiting Review',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Submissions Table
CREATE TABLE IF NOT EXISTS public.submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    application_id UUID REFERENCES public.applications(id) ON DELETE CASCADE,
    campaign_id UUID REFERENCES public.campaigns(id) ON DELETE CASCADE,
    campaign_title TEXT NOT NULL,
    creator_uid TEXT NOT NULL,
    video_url TEXT,
    views TEXT DEFAULT '0',
    likes TEXT DEFAULT '0',
    score NUMERIC(5, 2) DEFAULT 95.0,
    status TEXT DEFAULT 'Awaiting Review',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Reviews Table
CREATE TABLE IF NOT EXISTS public.reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id UUID REFERENCES public.submissions(id) ON DELETE CASCADE,
    reviewer TEXT NOT NULL,
    rating INTEGER CHECK (rating BETWEEN 1 AND 5),
    comment TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 6. Transactions Table
CREATE TABLE IF NOT EXISTS public.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_uid TEXT NOT NULL,
    campaign_id UUID REFERENCES public.campaigns(id) ON DELETE SET NULL,
    amount_etb NUMERIC(12, 2) NOT NULL,
    status TEXT DEFAULT 'Completed',
    description TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 7. Notifications Table
CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_uid TEXT NOT NULL,
    message TEXT NOT NULL,
    read BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes & Constraints
CREATE INDEX IF NOT EXISTS idx_users_uid ON public.users(firebase_uid);
CREATE INDEX IF NOT EXISTS idx_campaigns_type ON public.campaigns(type);
CREATE INDEX IF NOT EXISTS idx_applications_creator ON public.applications(creator_uid);
CREATE INDEX IF NOT EXISTS idx_submissions_campaign ON public.submissions(campaign_id);

-- Row Level Security (RLS)
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Public Read Policies
CREATE POLICY "Public campaigns read" ON public.campaigns FOR SELECT USING (true);

-- Leaderboard Views
CREATE OR REPLACE VIEW public.creator_leaderboard AS
SELECT 
    s.campaign_id,
    u.id,
    u.name,
    u.username,
    COALESCE(SUM(t.amount_etb), 75000) as score
FROM public.submissions s
JOIN public.users u ON u.firebase_uid = s.creator_uid
LEFT JOIN public.transactions t ON t.creator_uid = s.creator_uid
GROUP BY s.campaign_id, u.id, u.name, u.username
ORDER BY score DESC;

CREATE OR REPLACE VIEW public.challenge_givers_leaderboard AS
SELECT 
    c.brand AS name,
    COUNT(c.id) AS active_challenges,
    'ETB 6,800,000' AS total_prize_pool
FROM public.campaigns c
WHERE c.type = 'CHALLENGE'
GROUP BY c.brand
ORDER BY active_challenges DESC;

-- Seed 6 Initial Campaigns
INSERT INTO public.campaigns (id, title, brand, verified, type, reward, amount_num, requirements, deadline, slots, category, description, rules, image_url)
VALUES 
('c1000000-0000-0000-0000-000000000001', 'Summer Glow Up Challenge', 'GlowRecipe', true, 'CHALLENGE', 'ETB 550,000 Prize Pool', 550000, 'Min 5k followers • TikTok Video • #GlowUp2026', '4 days left', '142 joined', 'Beauty', 'Showcase your ultimate summer skincare routine using GlowRecipe dew drops. Create an engaging, high-energy transition video.', '["Must use official sound", "Original content only", "Tag @GlowRecipe in caption"]'::jsonb, 'https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/campaigns/glow_recipe.jpg'),
('c1000000-0000-0000-0000-000000000002', 'Next-Gen Wireless Earbuds Launch', 'SoundPulse', true, 'PROMOTION', 'ETB 85,000 Flat Fee', 85000, 'Min 25k followers • Product Unboxing Review', '6 days left', '1 slot available', 'Tech', 'Partner with SoundPulse for an exclusive first look at our active noise-cancelling wireless earbuds.', '["Showcase ANC feature", "Include purchase link in bio"]'::jsonb, 'https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/campaigns/soundpulse.jpg'),
('c1000000-0000-0000-0000-000000000003', 'Energy Drink TikTok Dance Off', 'BlitzEnergy', true, 'CHALLENGE', 'ETB 1,400,000 Grand Prize', 1400000, 'Open to all creators • Original choreography', '12 days left', '530 joined', 'Lifestyle', 'Hit the choreography with a can of Blitz Energy in hand. Most creative TikTok wins the ETB 800,000 first place check!', '["Use #BlitzDanceOff", "Keep video above 15 seconds"]'::jsonb, 'https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/campaigns/blitz_dance.jpg'),
('c1000000-0000-0000-0000-000000000004', 'Sustainable Streetwear Lookbook', 'EcoThreads', false, 'PROMOTION', 'ETB 45,000 Per Video', 45000, 'Min 10k followers • Fashion Try-On', '2 days left', '3 slots remaining', 'Fashion', 'Create a 3-outfit transition lookbook featuring our recycled autumn streetwear collection.', '["Clear lighting", "Show closeups of fabric texture"]'::jsonb, 'https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/campaigns/ecothreads.jpg'),
('c1000000-0000-0000-0000-000000000005', 'Indie Game Playtest & Reaction', 'PixelForge', true, 'PROMOTION', 'ETB 115,000 + Rev Share', 115000, 'Min 50k followers • Gaming Creator', '1 week left', '2 slots remaining', 'Gaming', 'Review our upcoming roguelike dungeon crawler live or in a dedicated 60s TikTok review.', '["Include gameplay footage", "Add game link"]'::jsonb, 'https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/campaigns/pixelforge.jpg'),
('c1000000-0000-0000-0000-000000000006', 'Quick Meal Prep Speedrun', 'FreshBites', true, 'CHALLENGE', 'ETB 275,000 Prize Pool', 275000, 'Open to all • Recipe TikTok', '3 days left', '210 joined', 'Food', 'Show us how you prep 3 healthy lunches in under 10 minutes using FreshBites meal kits.', '["Quick cuts required", "Must show final dish"]'::jsonb, 'https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/campaigns/pixelforge.jpg')
ON CONFLICT (id) DO NOTHING;
