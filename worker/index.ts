import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

export interface Env {
    FIREBASE_PROJECT_ID: string;
    SUPABASE_URL: string;
    SUPABASE_SECRET_KEY: string;
    R2_ACCESS_KEY_ID: string;
    R2_SECRET_ACCESS_KEY: string;
    CLOUDFLARE_ACCOUNT_ID: string;
    BUCKET_NAME: string;
    ALLOWED_ORIGIN: string;
}

let firebaseApp: any;

function getFirebaseAdmin(env: Env) {
    if (!firebaseApp) {
        firebaseApp = initializeApp({ projectId: env.FIREBASE_PROJECT_ID });
    }
    return getAuth(firebaseApp);
}

export default {
    async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
        const url = new URL(request.url);
        const path = url.pathname;
        const origin = request.headers.get('Origin') || '*';

        const corsHeaders = {
            'Access-Control-Allow-Origin': env.ALLOWED_ORIGIN || '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
            'Access-Control-Allow-Headers': 'Authorization, Content-Type',
        };

        if (request.method === 'OPTIONS') {
            return new Response(null, { headers: corsHeaders });
        }

        try {
            // 1. R2 Presigned Upload Signer
            if (path === '/api/uploads/sign' && request.method === 'POST') {
                const decoded = await verifyAuth(request, env);
                if (!decoded) return jsonResponse({ error: 'Unauthorized' }, 401, corsHeaders);

                const body: any = await request.json();
                const { fileName, fileType } = body;

                const allowedTypes = ['image/jpeg', 'image/png', 'image/webp', 'video/mp4'];
                if (!allowedTypes.includes(fileType)) {
                    return jsonResponse({ error: 'Invalid file type. Only JPEG, PNG, WEBP, and MP4 allowed.' }, 400, corsHeaders);
                }

                const uid = decoded.uid;
                const safeName = fileName.replace(/[^a-zA-Z0-9.-]/g, '_');
                const fileKey = `uploads/${uid}/${crypto.randomUUID()}-${safeName}`;

                const s3 = new S3Client({
                    region: 'auto',
                    endpoint: `https://${env.CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`,
                    credentials: {
                        accessKeyId: env.R2_ACCESS_KEY_ID,
                        secretAccessKey: env.R2_SECRET_ACCESS_KEY,
                    },
                });

                const command = new PutObjectCommand({
                    Bucket: env.BUCKET_NAME,
                    Key: fileKey,
                    ContentType: fileType,
                });

                const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 3600 });
                const publicUrl = `https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev/${fileKey}`;

                return jsonResponse({ uploadUrl, publicUrl }, 200, corsHeaders);
            }

            // 2. User Profile Route
            if (path === '/api/users/profile') {
                const decoded = await verifyAuth(request, env);
                if (!decoded) return jsonResponse({ error: 'Unauthorized' }, 401, corsHeaders);

                if (request.method === 'GET') {
                    const res = await supabaseQuery(env, `users?firebase_uid=eq.${decoded.uid}`);
                    if (res && res.length > 0) return jsonResponse(res[0], 200, corsHeaders);
                    return jsonResponse(null, 404, corsHeaders);
                }

                if (request.method === 'POST') {
                    const body: any = await request.json();
                    const profile = {
                        firebase_uid: decoded.uid,
                        email: decoded.email,
                        name: body.name,
                        username: body.username,
                        tiktok_username: body.tiktok_username,
                        category: body.category,
                        follower_range: body.follower_range,
                        role: body.role || 'creator'
                    };
                    const res = await supabaseMutation(env, 'users', 'POST', profile);
                    return jsonResponse(res[0] || profile, 201, corsHeaders);
                }
            }

            // 3. Applications Route
            if (path === '/api/applications') {
                const decoded = await verifyAuth(request, env);
                if (!decoded) return jsonResponse({ error: 'Unauthorized' }, 401, corsHeaders);

                if (request.method === 'GET') {
                    const res = await supabaseQuery(env, `applications?creator_uid=eq.${decoded.uid}`);
                    return jsonResponse(res || [], 200, corsHeaders);
                }

                if (request.method === 'POST') {
                    const body: any = await request.json();
                    const payload = {
                        campaign_id: body.campaign_id,
                        campaign_title: body.campaign_title,
                        creator_uid: decoded.uid,
                        video_idea: body.video_idea,
                        evidence_url: body.evidence_url,
                        status: 'Awaiting Review'
                    };
                    const res = await supabaseMutation(env, 'applications', 'POST', payload);
                    await supabaseMutation(env, 'submissions', 'POST', {
                        application_id: res[0]?.id,
                        campaign_id: body.campaign_id,
                        campaign_title: body.campaign_title,
                        creator_uid: decoded.uid,
                        status: 'Awaiting Review'
                    });
                    return jsonResponse(res[0] || payload, 201, corsHeaders);
                }
            }

            // 4. Transactions Route
            if (path === '/api/transactions' && request.method === 'GET') {
                const decoded = await verifyAuth(request, env);
                if (!decoded) return jsonResponse({ error: 'Unauthorized' }, 401, corsHeaders);
                const res = await supabaseQuery(env, `transactions?creator_uid=eq.${decoded.uid}`);
                return jsonResponse(res || [], 200, corsHeaders);
            }

            // 5. Notifications Route
            if (path === '/api/notifications') {
                const decoded = await verifyAuth(request, env);
                if (!decoded) return jsonResponse({ error: 'Unauthorized' }, 401, corsHeaders);
                const res = await supabaseQuery(env, `notifications?user_uid=eq.${decoded.uid}&order=created_at.desc`);
                return jsonResponse(res || [], 200, corsHeaders);
            }

            if (path.startsWith('/api/notifications/') && path.endsWith('/read') && request.method === 'PATCH') {
                const decoded = await verifyAuth(request, env);
                if (!decoded) return jsonResponse({ error: 'Unauthorized' }, 401, corsHeaders);
                const id = path.split('/')[3];
                await supabaseMutation(env, `notifications?id=eq.${id}`, 'PATCH', { read: true });
                return jsonResponse({ success: true }, 200, corsHeaders);
            }

            return jsonResponse({ error: 'Not Found' }, 404, corsHeaders);
        } catch (err: any) {
            return jsonResponse({ error: err.message || 'Internal Server Error' }, 500, corsHeaders);
        }
    },
};

async function verifyAuth(request: Request, env: Env) {
    const authHeader = request.headers.get('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) return null;
    const token = authHeader.split('Bearer ')[1];
    try {
        const auth = getFirebaseAdmin(env);
        const decoded = await auth.verifyIdToken(token);
        return decoded;
    } catch (e) {
        return null;
    }
}

async function supabaseQuery(env: Env, endpoint: string) {
    const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${endpoint}`, {
        headers: {
            'apikey': env.SUPABASE_SECRET_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SECRET_KEY}`,
            'Content-Type': 'application/json'
        }
    });
    if (!res.ok) return null;
    return await res.json();
}

async function supabaseMutation(env: Env, table: string, method: string, data: any) {
    const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${table}`, {
        method,
        headers: {
            'apikey': env.SUPABASE_SECRET_KEY,
            'Authorization': `Bearer ${env.SUPABASE_SECRET_KEY}`,
            'Content-Type': 'application/json',
            'Prefer': 'return=representation'
        },
        body: JSON.stringify(data)
    });
    if (!res.ok) {
        const txt = await res.text();
        throw new Error(txt || res.statusText);
    }
    const text = await res.text();
    return text ? JSON.parse(text) : [];
}

function jsonResponse(data: any, status = 200, headers = {}) {
    return new Response(JSON.stringify(data), {
        status,
        headers: { ...headers, 'Content-Type': 'application/json' }
    });
}
```
```toml:Wrangler Config:worker/wrangler.toml
name = "hawme-worker"
main = "index.ts"
compatibility_date = "2026-03-01"

[vars]
CLOUDFLARE_ACCOUNT_ID = "149acc27c103b48358ecfa01707b081d"
BUCKET_NAME = "hawme"
SUPABASE_URL = "https://akoddbuemubeorwfwonv.supabase.co"
FIREBASE_PROJECT_ID = "my-tiktok-cbd6f"
ALLOWED_ORIGIN = "https://pub-2b7577a8a0504c8896c8003d89c0fc7c.r2.dev"
