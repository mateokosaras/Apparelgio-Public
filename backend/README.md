# Apparelgio Backend

The backend keeps Gemini credentials off the iOS app. It exposes the health,
weather, authenticated garment-analysis, and outfit-recommendation routes used
by the Swift client. Weather is provided by Open-Meteo and requires no API key.

## Local development

```bash
npm install
npm run dev
```

Check the service at `http://localhost:3000/health`.

The authenticated weather route accepts simulator/device coordinates:

```bash
curl -H "Authorization: Bearer $APPWRITE_JWT" \
  "http://localhost:3000/weather?latitude=-16.5&longitude=-68.15"
```

Weather responses are cached for 15 minutes and the previous value is returned
when Open-Meteo is temporarily unavailable.

The local `.env.local` file should contain `GEMINI_API_KEY`, `GEMINI_MODEL`,
`APPWRITE_ENDPOINT`, and `APPWRITE_PROJECT_ID`. Protected requests must carry a
short-lived JWT created by the authenticated Appwrite account. The backend does
not accept Supabase tokens or a shared backend API key.

## Production environment

Set `NODE_ENV=production`, `PORT`, `GEMINI_API_KEY`, `GEMINI_MODEL`,
`APPWRITE_ENDPOINT`, `APPWRITE_PROJECT_ID`, and optionally `CORS_ORIGINS` and
`AI_REQUESTS_PER_MINUTE`, `OPEN_METEO_API_URL`. Do not copy `.env` or
`.env.local` into an image or commit them to the repository.

The included `Dockerfile` builds a minimal production image:

```bash
docker build -t apparelgio-backend .
docker run --env-file .env.production -p 3000:3000 apparelgio-backend
```

The production container validates its critical configuration at startup,
runs as the unprivileged `node` user, exposes a Docker health check, and
returns no browser CORS headers unless `CORS_ORIGINS` is explicitly set.

## Render deployment

The repository includes `render.yaml` in its root directory. In Render, create
a Blueprint from the repository and select the branch that contains the release
candidate. The Blueprint builds the Docker image from `backend/Dockerfile` with
`backend` as its context and uses the image `CMD` to start the service. It uses
`/health` as its health check.

Render asks for the value of `GEMINI_API_KEY` because it is marked as a secret.
The remaining Appwrite and runtime settings are declared in the Blueprint. Do
not add Supabase variables, API keys, JWTs, or local `.env` files to the
repository or to the Blueprint.

After deployment, verify the public service with:

```bash
curl https://YOUR-RENDER-SERVICE.onrender.com/health
```

The response must report `status: "ok"`, `geminiConfigured: true`,
`appwriteConfigured: true`, and `weatherProvider: "open-meteo"`.

## First cloud deployment checklist

1. Create an `.env.production` file outside Git from `.env.example`.
2. Set `NODE_ENV=production`, `GEMINI_API_KEY`, `GEMINI_MODEL`,
   `APPWRITE_ENDPOINT`, and `APPWRITE_PROJECT_ID` in the hosting provider's
   secret/environment settings. Do not upload `.env.local`.
3. Build and verify locally:

```bash
npm ci
npm test
docker build -t apparelgio-backend .
docker run --rm --env-file .env.production -p 3000:3000 apparelgio-backend
curl http://localhost:3000/health
```

4. Deploy the image to the selected HTTPS host and copy its URL into the
   app's backend configuration. Native iOS requests do not need CORS.
5. Verify `/health`, Appwrite JWT authentication, garment analysis, weather,
   outfit generation, and duplicate-safe outfit saving before TestFlight.

The Appwrite permission review checklist is in
`docs/appwrite-migration/security-checklist.md`.
