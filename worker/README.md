# HAWME backend setup

The frontend uses Firebase Authentication, the Cloudflare Worker API, Supabase Postgres, and Cloudflare R2. This repository contains the integration code; the cloud services still need to be configured by the project owner.

## 1. Apply the database schema

1. Open the Supabase project configured in \`index.html\`.
2. Open **SQL Editor**.
3. Run the complete \`supabase/schema.sql\` file.
4. Confirm that the tables, the \`apply_to_campaign\` RPC, and both leaderboard views were created.

The six seeded campaigns are clearly marked **DEMO**. They are not real sponsor offers or confirmed prizes. Replace them with genuine, permissioned campaign data before inviting creators.

If the unique application index fails, inspect and resolve existing duplicate rows in \`public.applications\` before rerunning the SQL. Do not delete real user records blindly.

## 2. Configure Cloudflare R2

1. Confirm the bucket name is \`hawme\`.
2. Create an R2 API token with object read/write permissions for that bucket.
3. Configure the bucket's CORS policy using \`r2-cors.json\`.
4. Add the exact origin of your deployed frontend to \`AllowedOrigins\`. Do not use a wildcard for a public production deployment.
5. Confirm the bucket has a public custom domain or public development URL matching \`PUBLIC_R2_BASE_URL\` in the Worker config. If you use a custom domain, update that variable to it.

The Worker signs uploads for JPEG, PNG, WEBP, and MP4 files. The browser uploads directly to R2; private R2 credentials never belong in the frontend.

## 3. Configure Firebase

The Firebase project ID is already referenced in the public frontend configuration and Worker config. In Firebase Console:

1. Enable Email/Password and Google sign-in providers.
2. Add your frontend hostname to **Authentication → Settings → Authorized domains**.
3. Check that the project ID matches \`FIREBASE_PROJECT_ID\` in \`worker/wrangler.toml\`.

The Worker verifies Firebase ID tokens against Google's Secure Token signing keys. It does not need a Firebase Admin service-account private key.

## 4. Configure Worker secrets

From a terminal:

\`\`\`bash
cd worker
npm install
npx wrangler secret put SUPABASE_SECRET_KEY
npx wrangler secret put R2_ACCESS_KEY_ID
npx wrangler secret put R2_SECRET_ACCESS_KEY
\`\`\`

Use the Supabase server-side secret/service-role credential, not the publishable key. Use the R2 access key and secret generated for the \`hawme\` bucket. Never commit these values or paste them into frontend code.

For local development, create \`worker/.dev.vars\` (this file is git-ignored) with:

\`\`\`dotenv
SUPABASE_SECRET_KEY=your_supabase_server_secret
R2_ACCESS_KEY_ID=your_r2_access_key
R2_SECRET_ACCESS_KEY=your_r2_secret
\`\`\`

Do not commit \`.dev.vars\`.

## 5. Run locally

In one terminal:

\`\`\`bash
cd worker
npm install
npm run dev
\`\`\`

The Worker listens at \`http://127.0.0.1:8787\`. Check:

\`\`\`bash
curl http://127.0.0.1:8787/api/health
\`\`\`

Serve the project root with a local static server at an allowed origin, for example \`http://127.0.0.1:5500\`. The frontend's \`workerUrl\` currently points to the local Worker. If you use another local port, add that exact origin to \`ALLOWED_ORIGINS\` in \`worker/wrangler.toml\` and to the R2 CORS configuration.

## 6. Production configuration

Before production:

1. Deploy the Worker from the \`worker\` directory with \`npx wrangler deploy\`.
2. Add your real frontend origin to \`ALLOWED_ORIGINS\` in \`worker/wrangler.toml\`.
3. Add that same origin to the R2 bucket CORS configuration.
4. Set the frontend \`CONFIG.workerUrl\` in \`index.html\` to the actual Worker URL shown by Wrangler.
5. Confirm \`PUBLIC_R2_BASE_URL\` matches the public R2 domain.
6. Configure all three Worker secrets in the production environment.
7. Test sign-up, sign-in, profile creation, campaign browsing, duplicate application rejection, upload, dashboard reads, and notification ownership.

Do not deploy while the frontend still points at localhost or while the allowed-origin list does not include the production frontend.

## API behavior

- \`GET /api/health\`: public Worker health check.
- \`GET /api/users/profile\`: current authenticated user's profile.
- \`POST /api/users/profile\`: creates/updates the authenticated user's creator profile. The role is assigned by the server; clients cannot promote themselves.
- \`POST /api/uploads/sign\`: creates a short-lived R2 upload URL scoped to the authenticated user's folder.
- \`GET /api/applications\`: current user's applications.
- \`POST /api/applications\`: atomically creates an application and its submission record. A creator can apply only once per campaign.
- \`GET /api/transactions\`: current user's transactions.
- \`GET /api/notifications\`: current user's notifications.
- \`PATCH /api/notifications/:id/read\`: marks only the current user's notification as read.

Campaign browsing and public leaderboards use the Supabase publishable key from the frontend. The Worker uses the server-side secret for protected operations and validates user identity before every private query.

## Current scope

This first backend pass supports creator registration and applications. Campaigns are managed by a trusted administrator through Supabase until a protected admin campaign-management interface is implemented. There is no automatic payment processing, sponsor onboarding, campaign approval workflow, or TikTok account verification in this version. A displayed ETB reward is not a payment guarantee.
