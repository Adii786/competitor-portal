-- ═══════════════════════════════════════════════════════════════════
-- DOLLAR STATIONERY — COMPETITOR INTEL PORTAL
-- Supabase Database Setup Script
-- Run this ONCE in your Supabase SQL Editor (supabase.com → SQL Editor)
-- ═══════════════════════════════════════════════════════════════════

-- ─── 1. PROFILES TABLE ──────────────────────────────────────────────
-- Stores extended user info (name, role, town) linked to auth.users
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   TEXT NOT NULL,
  email       TEXT,
  role        TEXT NOT NULL DEFAULT 'field'
              CHECK (role IN ('field','supervisor','rsm','ho')),
  town        TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Auto-create profile on signup using user metadata
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, role, town)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'role', 'field'),
    COALESCE(NEW.raw_user_meta_data->>'town', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ─── 2. SUBMISSIONS TABLE ────────────────────────────────────────────
-- One row per field person per fortnight period
CREATE TABLE IF NOT EXISTS public.submissions (
  id                  BIGSERIAL PRIMARY KEY,
  user_id             UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  period_key          TEXT NOT NULL,       -- e.g. "February_2025_1st (1–14)"
  period_month        TEXT NOT NULL,
  period_year         TEXT NOT NULL,
  period_fortnight    TEXT NOT NULL,
  full_name           TEXT NOT NULL,
  town                TEXT,
  total_products      INTEGER DEFAULT 0,
  new_product_count   INTEGER DEFAULT 0,
  submitted_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, period_key)             -- Prevent duplicate submissions
);

-- Add period_key index for fast filtering
CREATE INDEX IF NOT EXISTS idx_submissions_period ON public.submissions(period_key);
CREATE INDEX IF NOT EXISTS idx_submissions_user ON public.submissions(user_id);

-- ─── 3. SUBMISSION ENTRIES TABLE ────────────────────────────────────
-- One row per product per submission
CREATE TABLE IF NOT EXISTS public.submission_entries (
  id              BIGSERIAL PRIMARY KEY,
  submission_id   BIGINT NOT NULL REFERENCES public.submissions(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  period_key      TEXT,                   -- Denormalised for fast queries
  category        TEXT,
  company         TEXT,
  brand           TEXT,
  ranking         TEXT,
  pcs             TEXT,
  trade_price     NUMERIC(12,2) DEFAULT 0,
  discount_pct    NUMERIC(6,2)  DEFAULT 0,
  net_price       NUMERIC(12,2) DEFAULT 0,
  scheme          TEXT,
  notes           TEXT,
  is_new_product  BOOLEAN DEFAULT FALSE,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_entries_submission ON public.submission_entries(submission_id);
CREATE INDEX IF NOT EXISTS idx_entries_period    ON public.submission_entries(period_key);
CREATE INDEX IF NOT EXISTS idx_entries_category  ON public.submission_entries(category);
CREATE INDEX IF NOT EXISTS idx_entries_new       ON public.submission_entries(is_new_product);
CREATE INDEX IF NOT EXISTS idx_entries_user      ON public.submission_entries(user_id);

-- ─── 4. ROW LEVEL SECURITY (RLS) ────────────────────────────────────
-- CRITICAL: This ensures field staff can ONLY see their OWN data

ALTER TABLE public.profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submission_entries ENABLE ROW LEVEL SECURITY;

-- ── PROFILES policies ────────────────────────────────────────────────
-- Users can read their own profile
CREATE POLICY "Users read own profile"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

-- HO/RSM can read all profiles (for dashboard)
CREATE POLICY "HO RSM read all profiles"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
      AND p.role IN ('ho','rsm','supervisor')
    )
  );

-- Users can update their own profile
CREATE POLICY "Users update own profile"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id);

-- Service role can insert (for signup trigger)
CREATE POLICY "Service insert profile"
  ON public.profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

-- ── SUBMISSIONS policies ─────────────────────────────────────────────
-- Field staff: see only their OWN submissions
CREATE POLICY "Field see own submissions"
  ON public.submissions FOR SELECT
  USING (auth.uid() = user_id);

-- HO/RSM/Supervisor: see ALL submissions
CREATE POLICY "HO see all submissions"
  ON public.submissions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
      AND p.role IN ('ho','rsm','supervisor')
    )
  );

-- Anyone authenticated can insert their own submission
CREATE POLICY "Insert own submission"
  ON public.submissions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Can update only own submission
CREATE POLICY "Update own submission"
  ON public.submissions FOR UPDATE
  USING (auth.uid() = user_id);

-- Can delete only own submission (for re-submission overwrite)
CREATE POLICY "Delete own submission"
  ON public.submissions FOR DELETE
  USING (auth.uid() = user_id);

-- ── SUBMISSION ENTRIES policies ──────────────────────────────────────
-- Field staff: see only entries from their OWN submissions
CREATE POLICY "Field see own entries"
  ON public.submission_entries FOR SELECT
  USING (auth.uid() = user_id);

-- HO/RSM/Supervisor: see ALL entries
CREATE POLICY "HO see all entries"
  ON public.submission_entries FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid()
      AND p.role IN ('ho','rsm','supervisor')
    )
  );

-- Insert own entries
CREATE POLICY "Insert own entries"
  ON public.submission_entries FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- Delete own entries (for re-submission overwrite)
CREATE POLICY "Delete own entries"
  ON public.submission_entries FOR DELETE
  USING (auth.uid() = user_id);

-- ─── 5. USEFUL VIEWS (for HO analysis) ──────────────────────────────

-- Period summary view
CREATE OR REPLACE VIEW public.period_summary AS
SELECT
  s.period_key,
  s.period_month,
  s.period_year,
  s.period_fortnight,
  COUNT(DISTINCT s.id)           AS total_submissions,
  COUNT(DISTINCT s.user_id)      AS unique_submitters,
  SUM(s.total_products)          AS total_product_records,
  SUM(s.new_product_count)       AS total_new_products,
  MIN(s.submitted_at)            AS first_submission,
  MAX(s.submitted_at)            AS last_submission
FROM public.submissions s
GROUP BY s.period_key, s.period_month, s.period_year, s.period_fortnight
ORDER BY MAX(s.submitted_at) DESC;

-- Category price analysis view
CREATE OR REPLACE VIEW public.category_price_analysis AS
SELECT
  e.period_key,
  e.category,
  e.company,
  COUNT(*)                       AS entry_count,
  ROUND(AVG(e.trade_price),2)   AS avg_trade_price,
  ROUND(AVG(e.net_price),2)     AS avg_net_price,
  ROUND(AVG(e.discount_pct),2)  AS avg_discount_pct,
  MIN(e.net_price)              AS min_net_price,
  MAX(e.net_price)              AS max_net_price,
  COUNT(DISTINCT e.submission_id) AS reporting_towns
FROM public.submission_entries e
WHERE e.trade_price > 0
GROUP BY e.period_key, e.category, e.company
ORDER BY e.period_key DESC, e.category, avg_net_price;

-- New products intelligence view
CREATE OR REPLACE VIEW public.new_product_intel AS
SELECT
  e.id,
  e.created_at,
  e.period_key,
  e.category,
  e.company,
  e.brand,
  e.trade_price,
  e.net_price,
  e.discount_pct,
  e.scheme,
  e.notes,
  s.full_name  AS reported_by,
  s.town       AS reported_from,
  s.period_month,
  s.period_year
FROM public.submission_entries e
JOIN public.submissions s ON s.id = e.submission_id
WHERE e.is_new_product = TRUE
ORDER BY e.created_at DESC;

-- ─── 6. GRANT VIEW ACCESS ───────────────────────────────────────────
GRANT SELECT ON public.period_summary TO authenticated;
GRANT SELECT ON public.category_price_analysis TO authenticated;
GRANT SELECT ON public.new_product_intel TO authenticated;

-- ─── 7. ADMIN HELPER: Create your first HO admin user ───────────────
-- After running this script, sign up via the portal with your email.
-- Then run this command in SQL Editor to promote yourself to HO admin:
-- (Replace 'your@email.com' with your actual email)

-- UPDATE public.profiles SET role = 'ho' WHERE email = 'your@email.com';

-- ─── DONE ────────────────────────────────────────────────────────────
-- Your database is ready. Go back to the portal and enter your
-- Supabase Project URL and Anon Key to connect.
