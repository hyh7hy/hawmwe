-- HAWME database schema and integration migration.
-- Seed records are DEMO DATA only, not verified sponsorships.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.users (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 firebase_uid TEXT UNIQUE NOT NULL,
 email TEXT UNIQUE NOT NULL,
 name TEXT NOT NULL,
 username TEXT UNIQUE NOT NULL,
 tiktok_username TEXT NOT NULL,
 category TEXT NOT NULL,
 follower_range TEXT NOT NULL,
 role TEXT NOT NULL DEFAULT 'creator' CHECK (role IN ('creator','admin')),
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.campaigns (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 title TEXT NOT NULL,
 brand TEXT NOT NULL,
 verified BOOLEAN NOT NULL DEFAULT FALSE,
 type TEXT NOT NULL CHECK (type IN ('PROMOTION','CHALLENGE')),
 reward TEXT NOT NULL,
 amount_num NUMERIC(12,2) NOT NULL CHECK (amount_num >= 0),
 requirements TEXT NOT NULL,
 deadline TEXT NOT NULL,
 slots TEXT NOT NULL,
 category TEXT NOT NULL,
 description TEXT,
 rules JSONB,
 image_url TEXT,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.applications (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 campaign_id UUID NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
 campaign_title TEXT NOT NULL,
 creator_uid TEXT NOT NULL,
 video_idea TEXT,
 evidence_url TEXT,
 status TEXT NOT NULL DEFAULT 'Awaiting Review',
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.submissions (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 application_id UUID REFERENCES public.applications(id) ON DELETE CASCADE,
 campaign_id UUID NOT NULL REFERENCES public.campaigns(id) ON DELETE CASCADE,
 campaign_title TEXT NOT NULL,
 creator_uid TEXT NOT NULL,
 video_url TEXT,
 views TEXT DEFAULT '0',
 likes TEXT DEFAULT '0',
 score NUMERIC(12,2) DEFAULT 0,
 status TEXT NOT NULL DEFAULT 'Awaiting Review',
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.reviews (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 submission_id UUID REFERENCES public.submissions(id) ON DELETE CASCADE,
 reviewer TEXT NOT NULL,
 rating INTEGER CHECK (rating BETWEEN 1 AND 5),
 comment TEXT,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.transactions (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 creator_uid TEXT NOT NULL,
 campaign_id UUID REFERENCES public.campaigns(id) ON DELETE SET NULL,
 amount_etb NUMERIC(12,2) NOT NULL CHECK (amount_etb >= 0),
 status TEXT NOT NULL DEFAULT 'Completed',
 description TEXT NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS public.notifications (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 user_uid TEXT NOT NULL,
 message TEXT NOT NULL,
 read BOOLEAN NOT NULL DEFAULT FALSE,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_uid ON public.users(firebase_uid);
CREATE INDEX IF NOT EXISTS idx_campaigns_type ON public.campaigns(type);
CREATE INDEX IF NOT EXISTS idx_applications_creator ON public.applications(creator_uid);
CREATE INDEX IF NOT EXISTS idx_submissions_campaign ON public.submissions(campaign_id);
CREATE INDEX IF NOT EXISTS idx_transactions_creator_campaign ON public.transactions(creator_uid,campaign_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON public.notifications(user_uid,created_at DESC);
-- If old duplicate applications exist, clean them before creating this index.
CREATE UNIQUE INDEX IF NOT EXISTS uq_applications_campaign_creator ON public.applications(campaign_id,creator_uid);

-- Application + submission are inserted atomically in one Postgres transaction.
CREATE OR REPLACE FUNCTION public.apply_to_campaign(
 p_creator_uid TEXT, p_campaign_id UUID, p_video_idea TEXT, p_evidence_url TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 selected_campaign public.campaigns%ROWTYPE;
 created_application public.applications%ROWTYPE;
BEGIN
 SELECT * INTO selected_campaign FROM public.campaigns WHERE id=p_campaign_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Campaign not found' USING ERRCODE='P0002'; END IF;
 INSERT INTO public.applications(campaign_id,campaign_title,creator_uid,video_idea,evidence_url,status)
 VALUES(selected_campaign.id,selected_campaign.title,p_creator_uid,COALESCE(p_video_idea,''),p_evidence_url,'Awaiting Review')
 RETURNING * INTO created_application;
 INSERT INTO public.submissions(application_id,campaign_id,campaign_title,creator_uid,status)
 VALUES(created_application.id,selected_campaign.id,selected_campaign.title,p_creator_uid,'Awaiting Review');
 RETURN to_jsonb(created_application);
EXCEPTION WHEN unique_violation THEN
 RAISE EXCEPTION 'You have already applied to this campaign.' USING ERRCODE='23505';
END; $$;
REVOKE ALL ON FUNCTION public.apply_to_campaign(TEXT,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.apply_to_campaign(TEXT,UUID,TEXT,TEXT) TO service_role;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Public campaigns read" ON public.campaigns;
CREATE POLICY "Public campaigns read" ON public.campaigns FOR SELECT TO anon,authenticated USING(true);

-- Aggregate payments before joining, preventing duplicate sums from join fan-out.
CREATE OR REPLACE VIEW public.creator_leaderboard AS
WITH participants AS (SELECT DISTINCT campaign_id,creator_uid FROM public.submissions),
creator_scores AS (
 SELECT campaign_id,creator_uid,SUM(amount_etb) AS score
 FROM public.transactions WHERE campaign_id IS NOT NULL GROUP BY campaign_id,creator_uid
)
SELECT p.campaign_id,u.id,u.name,u.username,COALESCE(cs.score,0)::NUMERIC(12,2) AS score
FROM participants p JOIN public.users u ON u.firebase_uid=p.creator_uid
LEFT JOIN creator_scores cs ON cs.campaign_id=p.campaign_id AND cs.creator_uid=p.creator_uid;

CREATE OR REPLACE VIEW public.challenge_givers_leaderboard AS
SELECT brand AS name,COUNT(*)::INTEGER AS active_challenges,
 COALESCE(SUM(amount_num),0)::NUMERIC(14,2) AS total_prize_pool
FROM public.campaigns WHERE type='CHALLENGE' GROUP BY brand;
GRANT SELECT ON public.creator_leaderboard TO anon,authenticated;
GRANT SELECT ON public.challenge_givers_leaderboard TO anon,authenticated;

-- Clearly marked sample records for development only.
INSERT INTO public.campaigns(id,title,brand,verified,type,reward,amount_num,requirements,deadline,slots,category,description,rules,image_url)
VALUES
('c1000000-0000-0000-0000-000000000001','Summer Glow Up Challenge','GlowRecipe',false,'CHALLENGE','DEMO — ETB 550,000 Prize Pool',550000,'Demo only — no sponsor offer','Demo deadline','Demo slots','Beauty','Sample data only. Not a verified brand partnership.','["Demo data only"]'::jsonb,NULL),
('c1000000-0000-0000-0000-000000000002','Next-Gen Wireless Earbuds Launch','SoundPulse',false,'PROMOTION','DEMO — ETB 85,000 Flat Fee',85000,'Demo only — no sponsor offer','Demo deadline','Demo slots','Tech','Sample data only. Not a verified brand partnership.','["Demo data only"]'::jsonb,NULL),
('c1000000-0000-0000-0000-000000000003','Energy Drink TikTok Dance Off','BlitzEnergy',false,'CHALLENGE','DEMO — ETB 1,400,000 Grand Prize',1400000,'Demo only — no sponsor offer','Demo deadline','Demo slots','Lifestyle','Sample data only. Not a verified brand partnership.','["Demo data only"]'::jsonb,NULL),
('c1000000-0000-0000-0000-000000000004','Sustainable Streetwear Lookbook','EcoThreads',false,'PROMOTION','DEMO — ETB 45,000 Per Video',45000,'Demo only — no sponsor offer','Demo deadline','Demo slots','Fashion','Sample data only. Not a verified brand partnership.','["Demo data only"]'::jsonb,NULL),
('c1000000-0000-0000-0000-000000000005','Indie Game Playtest & Reaction','PixelForge',false,'PROMOTION','DEMO — ETB 115,000 + Rev Share',115000,'Demo only — no sponsor offer','Demo deadline','Demo slots','Gaming','Sample data only. Not a verified brand partnership.','["Demo data only"]'::jsonb,NULL),
('c1000000-0000-0000-0000-000000000006','Quick Meal Prep Speedrun','FreshBites',false,'CHALLENGE','DEMO — ETB 275,000 Prize Pool',275000,'Demo only — no sponsor offer','Demo deadline','Demo slots','Food','Sample data only. Not a verified brand partnership.','["Demo data only"]'::jsonb,NULL)
ON CONFLICT(id) DO NOTHING;
