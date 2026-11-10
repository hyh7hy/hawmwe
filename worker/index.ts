import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { createRemoteJWKSet, jwtVerify } from "jose";

export interface Env {
  FIREBASE_PROJECT_ID: string;
  SUPABASE_URL: string;
  SUPABASE_SECRET_KEY: string;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
  BUCKET_NAME: string;
  ALLOWED_ORIGINS: string;
  PUBLIC_R2_BASE_URL: string;
}
type UserClaims = { uid: string; email?: string };
const firebaseKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"));

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}
function allowedOrigins(env: Env): string[] {
  return (env.ALLOWED_ORIGINS || "").split(",").map(v => v.trim()).filter(Boolean);
}
function corsHeaders(request: Request, env: Env): Headers {
  const h = new Headers({
    "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin"
  });
  const origin = request.headers.get("Origin");
  if (origin && allowedOrigins(env).includes(origin)) h.set("Access-Control-Allow-Origin", origin);
  return h;
}
function json(data: unknown, status = 200, headers?: Headers): Response {
  const h = new Headers(headers);
  h.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(data), { status, headers: h });
}
async function readJson(request: Request): Promise<Record<string, unknown>> {
  const value = await request.json();
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new HttpError(400, "Request body must be a JSON object.");
  return value as Record<string, unknown>;
}
async function verifyAuth(request: Request, env: Env): Promise<UserClaims> {
  const header = request.headers.get("Authorization") || "";
  if (!header.startsWith("Bearer ")) throw new HttpError(401, "Sign in to continue.");
  try {
    const { payload } = await jwtVerify(header.slice(7).trim(), firebaseKeys, {
      algorithms: ["RS256"],
      issuer: "https://securetoken.google.com/" + env.FIREBASE_PROJECT_ID,
      audience: env.FIREBASE_PROJECT_ID
    });
    if (typeof payload.sub !== "string" || !payload.sub || payload.sub.length > 128) throw new Error("Invalid subject");
    return { uid: payload.sub, email: typeof payload.email === "string" ? payload.email : undefined };
  } catch {
    throw new HttpError(401, "Your session is invalid or expired. Please sign in again.");
  }
}
function supabaseEndpoint(env: Env, endpoint: string): URL {
  return new URL(env.SUPABASE_URL.replace(/\/+$/, "") + "/rest/v1/" + endpoint);
}
async function supabaseRequest(env: Env, endpoint: string, method = "GET", body?: unknown, prefer?: string): Promise<any> {
  const headers = new Headers({
    apikey: env.SUPABASE_SECRET_KEY,
    Authorization: "Bearer " + env.SUPABASE_SECRET_KEY,
    "Content-Type": "application/json"
  });
  if (prefer) headers.set("Prefer", prefer);
  const response = await fetch(supabaseEndpoint(env, endpoint), {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body)
  });
  const raw = await response.text();
  let data: any = null;
  try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
  if (!response.ok) {
    const message = data && typeof data === "object" ? (data.message || data.details || data.hint || data.error) : data;
    throw new HttpError(response.status >= 500 ? 502 : response.status, String(message || "Database request failed."));
  }
  return data;
}
function requireString(value: unknown, field: string, max: number): string {
  if (typeof value !== "string") throw new HttpError(400, field + " is required.");
  const cleaned = value.trim();
  if (!cleaned || cleaned.length > max) throw new HttpError(400, field + " must be between 1 and " + max + " characters.");
  return cleaned;
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const headers = corsHeaders(request, env);
    const origin = request.headers.get("Origin");
    if (origin && !allowedOrigins(env).includes(origin)) return json({ error: "This website origin is not allowed." }, 403, headers);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    const path = new URL(request.url).pathname;
    try {
      if (path === "/api/health" && request.method === "GET") return json({ status: "ok", service: "hawme-worker" }, 200, headers);

      if (path === "/api/users/profile" && request.method === "GET") {
        const user = await verifyAuth(request, env);
        const rows = await supabaseRequest(env, "users?firebase_uid=eq." + encodeURIComponent(user.uid) + "&limit=1");
        return rows?.length ? json(rows[0], 200, headers) : json({ error: "Profile not found." }, 404, headers);
      }

      if (path === "/api/users/profile" && request.method === "POST") {
        const user = await verifyAuth(request, env);
        const body = await readJson(request);
        const name = requireString(body.name, "Name", 80);
        const username = requireString(body.username, "Username", 25);
        const tiktokUsername = requireString(body.tiktok_username, "TikTok username", 30);
        const category = requireString(body.category, "Category", 60);
        const followerRange = requireString(body.follower_range, "Follower range", 40);
        if (!/^@[a-zA-Z0-9_.]{3,24}$/.test(username)) throw new HttpError(400, "Username must start with @ and contain 3–24 valid characters.");
        if (!/^@?[a-zA-Z0-9_.]{2,24}$/.test(tiktokUsername)) throw new HttpError(400, "TikTok username is invalid.");
        if (!user.email) throw new HttpError(400, "Your Firebase account must have an email address.");
        const profile = {
          firebase_uid: user.uid, email: user.email, name, username,
          tiktok_username: tiktokUsername.startsWith("@") ? tiktokUsername : "@" + tiktokUsername,
          category, follower_range: followerRange, role: "creator"
        };
        const rows = await supabaseRequest(env, "users?on_conflict=firebase_uid", "POST", profile, "resolution=merge-duplicates,return=representation");
        return json(rows?.[0] || profile, 200, headers);
      }

      if (path === "/api/uploads/sign" && request.method === "POST") {
        const user = await verifyAuth(request, env);
        const body = await readJson(request);
        const fileName = requireString(body.fileName, "File name", 180);
        const fileType = requireString(body.fileType, "File type", 80);
        const fileSize = Number(body.fileSize);
        if (!["image/jpeg", "image/png", "image/webp", "video/mp4"].includes(fileType)) throw new HttpError(400, "Only JPEG, PNG, WEBP and MP4 files are allowed.");
        if (!Number.isFinite(fileSize) || fileSize <= 0 || fileSize > 50 * 1024 * 1024) throw new HttpError(400, "File must be smaller than 50 MB.");
        if (!env.PUBLIC_R2_BASE_URL) throw new HttpError(503, "R2 public URL is not configured.");
        const safeName = fileName.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-120) || "upload";
        const key = "uploads/" + user.uid + "/" + crypto.randomUUID() + "-" + safeName;
        const s3 = new S3Client({
          region: "auto",
          endpoint: "https://" + env.CLOUDFLARE_ACCOUNT_ID + ".r2.cloudflarestorage.com",
          credentials: { accessKeyId: env.R2_ACCESS_KEY_ID, secretAccessKey: env.R2_SECRET_ACCESS_KEY }
        });
        const command = new PutObjectCommand({ Bucket: env.BUCKET_NAME, Key: key, ContentType: fileType });
        const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 900 });
        const publicUrl = env.PUBLIC_R2_BASE_URL.replace(/\/+$/, "") + "/" + key;
        return json({ uploadUrl, publicUrl, key, expiresIn: 900 }, 200, headers);
      }

      if (path === "/api/applications" && request.method === "GET") {
        const user = await verifyAuth(request, env);
        const rows = await supabaseRequest(env, "applications?creator_uid=eq." + encodeURIComponent(user.uid) + "&order=created_at.desc");
        return json(rows || [], 200, headers);
      }

      if (path === "/api/applications" && request.method === "POST") {
        const user = await verifyAuth(request, env);
        const body = await readJson(request);
        const campaignId = requireString(body.campaign_id, "Campaign ID", 36);
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(campaignId)) throw new HttpError(400, "Campaign ID is invalid.");
        const videoIdea = typeof body.video_idea === "string" ? body.video_idea.trim().slice(0, 3000) : "";
        const evidenceUrl = body.evidence_url == null ? null : requireString(body.evidence_url, "Evidence URL", 2048);
        if (evidenceUrl) {
          const prefix = env.PUBLIC_R2_BASE_URL.replace(/\/+$/, "") + "/uploads/" + user.uid + "/";
          if (!evidenceUrl.startsWith(prefix)) throw new HttpError(400, "Evidence must be uploaded to your own HAWME upload folder.");
        }
        const result = await supabaseRequest(env, "rpc/apply_to_campaign", "POST", {
          p_creator_uid: user.uid, p_campaign_id: campaignId, p_video_idea: videoIdea, p_evidence_url: evidenceUrl
        });
        return json(result, 201, headers);
      }

      if (path === "/api/transactions" && request.method === "GET") {
        const user = await verifyAuth(request, env);
        const rows = await supabaseRequest(env, "transactions?creator_uid=eq." + encodeURIComponent(user.uid) + "&order=created_at.desc");
        return json(rows || [], 200, headers);
      }

      if (path === "/api/notifications" && request.method === "GET") {
        const user = await verifyAuth(request, env);
        const rows = await supabaseRequest(env, "notifications?user_uid=eq." + encodeURIComponent(user.uid) + "&order=created_at.desc");
        return json(rows || [], 200, headers);
      }

      const match = path.match(/^\/api\/notifications\/([0-9a-f-]{36})\/read$/i);
      if (match && request.method === "PATCH") {
        const user = await verifyAuth(request, env);
        await supabaseRequest(env, "notifications?id=eq." + match[1] + "&user_uid=eq." + encodeURIComponent(user.uid), "PATCH", { read: true }, "return=minimal");
        return json({ success: true }, 200, headers);
      }
      return json({ error: "Not found." }, 404, headers);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.message }, error.status, headers);
      return json({ error: "Unexpected server error. Check Worker logs for details." }, 500, headers);
    }
  }
};
