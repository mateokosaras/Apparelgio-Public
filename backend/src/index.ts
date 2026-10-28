import express, { NextFunction, Request, Response } from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import multer from 'multer';
import sharp from 'sharp';

dotenv.config();
dotenv.config({ path: '.env.local', override: false });

const app = express();
const port = Number(process.env.PORT ?? 3000);
const isProduction = process.env.NODE_ENV === 'production';
const geminiAPIKey = process.env.GEMINI_API_KEY?.trim() ?? '';
const geminiModel = process.env.GEMINI_MODEL?.trim() || 'gemini-3.5-flash-lite';
const appwriteEndpoint = (process.env.APPWRITE_ENDPOINT?.trim() || 'https://nyc.cloud.appwrite.io/v1').replace(/\/$/, '');
const appwriteProjectID = process.env.APPWRITE_PROJECT_ID?.trim() || '6aa3ef4e000648946540';
const aiRequestsPerMinute = Math.max(1, Number(process.env.AI_REQUESTS_PER_MINUTE ?? 30));
const openMeteoAPIURL = process.env.OPEN_METEO_API_URL?.trim() || 'https://api.open-meteo.com/v1/forecast';
const weatherCacheLifetimeMs = 15 * 60 * 1_000;
const geminiRequestTimeoutMs = Math.max(10_000, Number(process.env.GEMINI_REQUEST_TIMEOUT_MS ?? 20_000));
const geminiMaxAttempts = Math.max(1, Number(process.env.GEMINI_MAX_ATTEMPTS ?? 2));
const geminiRetryDelayMs = Math.max(250, Number(process.env.GEMINI_RETRY_DELAY_MS ?? 800));
const allowedOrigins = (process.env.CORS_ORIGINS ?? '')
    .split(',')
    .map(origin => origin.trim())
    .filter(Boolean);

const externalRequestTimeoutMs = Math.max(3_000, Number(process.env.EXTERNAL_REQUEST_TIMEOUT_MS ?? 10_000));

if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error('PORT must be an integer between 1 and 65535.');
}

if (isProduction) {
    const missingProductionSettings = [
        ['GEMINI_API_KEY', geminiAPIKey],
        ['APPWRITE_ENDPOINT', appwriteEndpoint],
        ['APPWRITE_PROJECT_ID', appwriteProjectID]
    ]
        .filter(([, value]) => !value)
        .map(([name]) => name);

    if (missingProductionSettings.length > 0) {
        throw new Error(`Missing production configuration: ${missingProductionSettings.join(', ')}.`);
    }
}

type RateLimitState = { windowStartedAt: number; count: number };
const aiRateLimits = new Map<string, RateLimitState>();
const weatherCache = new Map<string, WeatherCacheEntry>();

const upload = multer({
    storage: multer.memoryStorage(),
    limits: {
        fileSize: 8 * 1024 * 1024,
        files: 1,
        fields: 4,
        fieldSize: 16 * 1024,
        parts: 5
    },
    fileFilter: (_request, file, callback) => {
        if (file.mimetype === 'image/jpeg' || file.mimetype === 'image/png' || file.mimetype === 'image/heic') {
            callback(null, true);
            return;
        }

        callback(new Error('Only JPEG, PNG, and HEIC garment images are accepted.'));
    }
});

const garmentCategories = ['Tops', 'Bottoms', 'Outerwear', 'Footwear', 'Accessories', 'Formalwear', 'Activewear'] as const;
const garmentTypes = ['Shirt', 'Blazer', 'Jeans', 'Dress', 'Shoes', 'Coat', 'Accessory', 'Trouser', 'Sneaker', 'Loafer', 'Bag', 'Belt', 'Tie'] as const;
const colors = ['Black', 'White', 'Ivory', 'Cream', 'Gray', 'Navy', 'Blue', 'Camel', 'Brown', 'Beige', 'Gold', 'Red', 'Green', 'Pink'] as const;
const formalities = ['Casual', 'Smart casual', 'Business', 'Cocktail', 'Formal'] as const;
const fits = ['Slim', 'Relaxed', 'Oversized', 'Tailored', 'Cropped', 'Wide-leg', 'Structured'] as const;
const materials = ['Cotton', 'Wool', 'Denim', 'Silk', 'Leather', 'Linen', 'Knit', 'Synthetic', 'Cashmere', 'Technical'] as const;
const patterns = ['Solid', 'Striped', 'Floral', 'Checked', 'Ribbed', 'Satin', 'Textured', 'Print'] as const;
const laundryStates = ['Ready', 'Worn once', 'Laundry', 'Dry clean', 'Repair'] as const;

type GarmentCategory = typeof garmentCategories[number];
type GarmentType = typeof garmentTypes[number];
type WardrobeColor = typeof colors[number];
type Formality = typeof formalities[number];
type Fit = typeof fits[number];
type Material = typeof materials[number];
type Pattern = typeof patterns[number];
type LaundryState = typeof laundryStates[number];

interface GarmentAnalysisResult {
    name: string;
    category: GarmentCategory;
    subcategory: GarmentType;
    primaryColor: WardrobeColor;
    secondaryColors: WardrobeColor[];
    formality: Formality;
    fit: Fit;
    warmth: number;
    material: Material;
    pattern: Pattern;
    occasions: string[];
    brand: string;
    condition: string;
    laundryStatus: LaundryState;
    imageToken: string;
    confidence: number;
}

export interface GarmentSummary {
    name: string;
    category: GarmentCategory;
    subcategory: GarmentType;
    primaryColor: WardrobeColor;
    secondaryColors: WardrobeColor[];
    formality: Formality;
    fit: Fit;
    warmth: number;
    material: Material;
    pattern: Pattern;
    occasions: string[];
    laundryStatus: LaundryState;
    isFavorite: boolean;
    wearCount: number;
    lastWorn: string | null;
}

interface UserProfileSummary {
    displayName: string;
    gender?: string | null;
    age?: number | null;
    lifestyleBaselines: string[];
    coreStyleArchetypes: string[];
    neutralColorPreferences: string[];
    colorExpression: string;
    fitSilhouette: string;
    climateComfort: string;
}

export interface OutfitPrompt {
    weather: string;
    occasion: string;
    contextNote?: string;
    dressCode: string;
    formalityLevel?: number | null;
    includeAccessories?: boolean;
    colorPreferences: string;
    timeAvailable: string;
    laundry: string;
    favorites: string;
    specificRequirements: string[];
    excludedGarments: string[];
    recentlyRecommendedGarments: string[];
}

interface OutfitDraft {
    title: string;
    occasion: string;
    weather: string;
    dressCode: string;
    itemNames: string[];
    missingPieces: string[];
    rationale: string;
    weatherNote: string;
    colorExplanation: string;
    stylingInstructions: string;
}

interface WeatherContextResponse {
    summary: string;
    temperature: number;
    condition: string;
    precipitationChance: number;
    stylingNote: string;
    source: 'open-meteo';
    stale?: boolean;
    fetchedAt: string;
}

interface WeatherCacheEntry {
    context: WeatherContextResponse;
    expiresAt: number;
}

app.disable('x-powered-by');
if (isProduction) {
    app.set('trust proxy', 1);
}
app.use((_request: Request, response: Response, next: NextFunction) => {
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('X-Frame-Options', 'DENY');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Pragma', 'no-cache');
    response.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
    response.setHeader('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    if (isProduction) {
        response.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    }
    next();
});
app.use(cors({
    // Native iOS requests do not require CORS. In production, deny browser
    // origins until an explicit allowlist is configured.
    origin: allowedOrigins.length === 0 ? (isProduction ? false : true) : allowedOrigins
}));
app.use(express.json({ limit: '256kb' }));

app.get('/health', (_request: Request, response: Response) => {
    response.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        geminiConfigured: Boolean(geminiAPIKey),
        geminiModel: geminiAPIKey ? geminiModel : null,
        appwriteConfigured: Boolean(appwriteEndpoint && appwriteProjectID),
        weatherProvider: 'open-meteo'
    });
});

// Identity-token verification needs Apple's and Google's public-key validation.
// Until that is implemented, this endpoint is explicitly unavailable rather than
// creating a misleading, forgeable "mock" session.
app.post('/auth/verify', (_request: Request, response: Response) => {
    response.status(501).json({
        error: 'Provider token verification is not implemented yet.'
    });
});

async function requireAuth(request: Request, response: Response, next: NextFunction): Promise<void> {
    const header = request.header('Authorization');
    const token = header?.startsWith('Bearer ') ? header.slice('Bearer '.length) : '';

    if (!token) {
        response.status(401).json({ error: 'Missing authorization token.' });
        return;
    }

    const appwriteUser = await getAppwriteUser(token);
    if (appwriteUser) {
        (request as any).user = appwriteUser;
        (request as any).authProvider = 'appwrite';
        next();
        return;
    }

    response.status(401).json({ error: 'Invalid Appwrite authorization token.' });
}

async function getAppwriteUser(token: string): Promise<Record<string, unknown> | null> {
    try {
        const accountResponse = await fetch(`${appwriteEndpoint}/account`, {
            method: 'GET',
            signal: AbortSignal.timeout(externalRequestTimeoutMs),
            headers: {
                'X-Appwrite-Project': appwriteProjectID,
                'X-Appwrite-JWT': token,
                'Accept': 'application/json'
            }
        });

        if (!accountResponse.ok) {
            return null;
        }

        const user = await accountResponse.json() as unknown;
        return user && typeof user === 'object' ? user as Record<string, unknown> : null;
    } catch {
        return null;
    }
}

app.get('/weather', requireAuth, async (request: Request, response: Response): Promise<void> => {
    const latitude = coordinateValue(request.query.latitude, -90, 90);
    const longitude = coordinateValue(request.query.longitude, -180, 180);

    if (latitude === null || longitude === null) {
        response.status(400).json({
            error: 'Valid latitude and longitude query parameters are required.'
        });
        return;
    }

    const cacheKey = [latitude.toFixed(3), longitude.toFixed(3)].join(',');
    const cached = weatherCache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) {
        response.json(cached.context);
        return;
    }

    try {
        const query = new URLSearchParams({
            latitude: String(latitude),
            longitude: String(longitude),
            current: 'temperature_2m,weather_code',
            hourly: 'precipitation_probability',
            forecast_hours: '3',
            temperature_unit: 'fahrenheit',
            timezone: 'auto'
        });
        const upstreamURL = openMeteoAPIURL + '?' + query.toString();
        const upstreamResponse = await fetch(upstreamURL, {
            signal: AbortSignal.timeout(externalRequestTimeoutMs),
            headers: { Accept: 'application/json' }
        });

        if (!upstreamResponse.ok) {
            throw new Error('Open-Meteo returned HTTP ' + upstreamResponse.status + '.');
        }

        const payload = await upstreamResponse.json() as OpenMeteoResponse;
        const temperature = finiteNumber(payload.current?.temperature_2m);
        const weatherCode = finiteNumber(payload.current?.weather_code);
        if (temperature === null || weatherCode === null) {
            throw new Error('Open-Meteo returned an incomplete current weather payload.');
        }

        const precipitationChance = Math.round(
            Math.max(
                0,
                ...((payload.hourly?.precipitation_probability ?? [])
                    .slice(0, 3)
                    .map(value => finiteNumber(value) ?? 0))
            )
        );
        const condition = weatherCondition(Math.round(weatherCode));
        const roundedTemperature = Math.round(temperature);
        const context: WeatherContextResponse = {
            summary: condition + ', ' + roundedTemperature + '°F, ' + precipitationChance + '% rain',
            temperature: roundedTemperature,
            condition,
            precipitationChance,
            stylingNote: weatherStylingNote(roundedTemperature, condition, precipitationChance),
            source: 'open-meteo',
            fetchedAt: new Date().toISOString()
        };

        weatherCache.set(cacheKey, {
            context,
            expiresAt: Date.now() + weatherCacheLifetimeMs
        });
        response.json(context);
    } catch (error) {
        console.error('Weather lookup failed:', error);
        const stale = weatherCache.get(cacheKey);
        if (stale) {
            response.json({
                ...stale.context,
                stale: true
            });
            return;
        }

        response.status(502).json({
            error: 'The weather service is temporarily unavailable.'
        });
    }
});

interface OpenMeteoResponse {
    current?: {
        temperature_2m?: unknown;
        weather_code?: unknown;
    };
    hourly?: {
        precipitation_probability?: unknown[];
    };
}

function coordinateValue(value: unknown, minimum: number, maximum: number): number | null {
    const raw = Array.isArray(value) ? value[0] : value;
    if (typeof raw !== 'string' && typeof raw !== 'number') return null;
    const parsed = Number(raw);
    return Number.isFinite(parsed) && parsed >= minimum && parsed <= maximum ? parsed : null;
}

function finiteNumber(value: unknown): number | null {
    return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function weatherCondition(code: number): string {
    if (code === 0) return 'Clear sky';
    if ([1, 2, 3].includes(code)) return 'Partly cloudy';
    if ([45, 48].includes(code)) return 'Foggy';
    if ([51, 53, 55, 56, 57].includes(code)) return 'Drizzle';
    if ([61, 63, 65, 66, 67, 80, 81, 82].includes(code)) return 'Rain';
    if ([71, 73, 75, 77, 85, 86].includes(code)) return 'Snow';
    if ([95, 96, 99].includes(code)) return 'Thunderstorms';
    return 'Changing conditions';
}

function weatherStylingNote(temperature: number, condition: string, precipitationChance: number): string {
    const lowercasedCondition = condition.toLowerCase();
    const wet = precipitationChance >= 35 || lowercasedCondition.includes('rain') || lowercasedCondition.includes('snow');

    if (temperature <= 55) {
        return wet
            ? 'Choose a warm outer layer and weather-ready shoes; keep the outfit easy to protect from rain.'
            : 'Choose a warm layer and keep the silhouette comfortable for cooler conditions.';
    }

    if (temperature >= 80) {
        return wet
            ? 'Keep the base breathable and add weather-ready details without heavy layering.'
            : 'Keep the outfit breathable and lightweight; avoid unnecessary heavy layers.';
    }

    return wet
        ? 'Use a light protective layer and shoes that can handle changing conditions.'
        : 'Light layers are enough; keep the outfit balanced and easy to adjust.';
}

function allowAIRequest(request: Request, response: Response): boolean {
    const user = (request as any).user as Record<string, unknown> | undefined;
    const userID = user?.$id ?? user?.id;
    const key = typeof userID === 'string' && userID.length > 0
        ? `user:${userID}`
        : `ip:${request.ip}`;
    const now = Date.now();
    const current = aiRateLimits.get(key);

    if (!current || now - current.windowStartedAt >= 60_000) {
        aiRateLimits.set(key, { windowStartedAt: now, count: 1 });
        return true;
    }

    if (current.count >= aiRequestsPerMinute) {
        const retryAfter = Math.max(1, Math.ceil((60_000 - (now - current.windowStartedAt)) / 1_000));
        response.setHeader('Retry-After', String(retryAfter));
        response.status(429).json({ error: 'AI request limit reached. Please try again shortly.' });
        return false;
    }

    current.count += 1;
    return true;
}

app.post(
    '/ai/garment-analysis',
    requireAuth,
    upload.single('image'),
    async (request: Request, response: Response): Promise<void> => {
        if (!allowAIRequest(request, response)) return;
        const source = stringValue(request.body?.source, 'photos');
        const fallback = fallbackGarmentResult(source);

        if (!request.file) {
            response.status(400).json({ error: 'A garment image is required.' });
            return;
        }

        if (!geminiAPIKey) {
            response.json({
                result: fallback,
                warning: 'Gemini garment analysis is not configured on the backend. Add GEMINI_API_KEY.'
            });
            return;
        }

        try {
            const optimizedImage = await sharp(request.file.buffer)
                .rotate()
                .resize({ width: 1_024, height: 1_024, fit: 'inside', withoutEnlargement: true })
                .jpeg({ quality: 78, mozjpeg: true })
                .toBuffer();

            const rawResult = await analyzeWithGemini(optimizedImage);
            response.json({ result: normalizeGarmentResult(rawResult, fallback) });
        } catch (error) {
            console.error('Garment analysis failed:', error);
            // A valid fallback lets the iOS user correct fields and save the image,
            // while avoiding unnecessary loss of a capture on an AI outage.
            response.json({ result: fallback, warning: 'Gemini could not analyze this image; editable defaults were used.' });
        }
    }
);

interface OutfitRecommendationRequest {
    prompt: OutfitPrompt;
    garments: GarmentSummary[];
    profile: UserProfileSummary | null;
}

export interface CandidateOutfit {
    items: GarmentSummary[];
    missingPieces: string[];
}

interface StyleIntent {
    desiredFormalities: string[];
    occasionTerms: string[];
    preferredCategories: string[];
    formalityLevel: number | null;
    hasSpecificContext: boolean;
    surpriseMe: boolean;
    active: boolean;
    dressy: boolean;
    shouldLayer: boolean;
    avoidAccessories: boolean;
}

interface WeatherIntent {
    cold: boolean;
    hot: boolean;
    wet: boolean;
    targetWarmth: number;
}

function generateShortlist(prompt: OutfitPrompt, garments: GarmentSummary[], profile: UserProfileSummary | null): CandidateOutfit[] {
    prompt = normalizeOutfitPrompt(prompt);
    const intent = buildStyleIntent(prompt);
    const weather = parseWeatherIntent(prompt.weather, profile);
    const excludedNames = new Set(uniqueStrings(prompt.excludedGarments).map(normalizeText));
    const unavailableLaundry = new Set(['laundry', 'dry clean', 'repair']);
    const available = garments.filter(garment => {
        const name = normalizeText(garment.name);
        const laundry = normalizeText(garment.laundryStatus);
        return name.length > 0 && !excludedNames.has(name) && !unavailableLaundry.has(laundry);
    });

    const requiredNames = new Set(uniqueStrings(prompt.specificRequirements).map(normalizeText));
    const requiredGarments = available.filter(garment => requiredNames.has(normalizeText(garment.name)));
    let tops = available.filter(isTop);
    let bottoms = available.filter(isBottom);
    const shoes = available.filter(isFootwear);
    const dresses = available.filter(isDress);
    const outerwear = available.filter(isOuterwear);
    const accessories = available.filter(isAccessory);

    // For active requests, denim, tailoring and ordinary casual bottoms are
    // not acceptable substitutes when the wardrobe contains real activewear.
    // If no active bottom exists, keep the look partial and report the missing
    // piece instead of producing a visually complete but unsuitable gym look.
    if (intent.active) {
        tops = tops.filter(isActiveCompatible);
        bottoms = bottoms.filter(isActiveCompatible);
    }
    const candidates: CandidateOutfit[] = [];

    // Generate complete looks first. Partial looks are added as a deliberate
    // fallback, so a missing shoe or bottom is reported instead of silently
    // filling the outfit with unrelated garments.
    for (const dress of dresses) {
        for (const shoe of shoes) pushCandidate(candidates, [dress, shoe], prompt);
    }
    for (const top of tops) {
        for (const bottom of bottoms) {
            for (const shoe of shoes) pushCandidate(candidates, [top, bottom, shoe], prompt);
        }
    }
    for (const top of tops) {
        for (const bottom of bottoms) pushCandidate(candidates, [top, bottom], prompt);
    }
    for (const top of tops) {
        for (const shoe of shoes) pushCandidate(candidates, [top, shoe], prompt);
    }
    for (const bottom of bottoms) {
        for (const shoe of shoes) pushCandidate(candidates, [bottom, shoe], prompt);
    }
    if (candidates.length === 0) {
        for (const garment of available) pushCandidate(candidates, [garment], prompt);
    }

    // Required tops, bottoms, dresses and shoes must be present. Accessories
    // and layers can be appended to the best compatible base look below.
    const requiredCore = requiredGarments.filter(garment => !isAccessory(garment) && !isOuterwear(garment));
    if (requiredCore.length > 0) {
        const strictCore = candidates.filter(candidate => requiredCore.every(required =>
            candidate.items.some(item => normalizeText(item.name) === normalizeText(required.name))
        ));
        const partialCore = candidates.filter(candidate => requiredCore.some(required =>
            candidate.items.some(item => normalizeText(item.name) === normalizeText(required.name))
        ));
        if (strictCore.length > 0) {
            candidates.splice(0, candidates.length, ...strictCore);
        } else if (partialCore.length > 0) {
            candidates.splice(0, candidates.length, ...partialCore);
        }
    }

    if (intent.shouldLayer && outerwear.length > 0) {
        const baseCandidates = candidates.slice(0, 160);
        for (const candidate of baseCandidates) {
            if (candidate.items.some(isOuterwear)) continue;
            for (const layer of outerwear) {
                pushCandidate(candidates, [...candidate.items, layer], prompt);
            }
        }
    }

    const requiredLayers = requiredGarments.filter(isOuterwear);
    const requiredAccessories = requiredGarments.filter(isAccessory);
    if (requiredLayers.length > 0 || requiredAccessories.length > 0) {
        const supplemental = [...requiredLayers, ...requiredAccessories];
        const expanded = candidates.map(candidate => pushRequiredItems(candidate, supplemental, prompt));
        candidates.splice(0, candidates.length, ...expanded);
    }

    // Optional accessories are controlled explicitly by the user. Required
    // accessories remain hard constraints and are handled separately above.
    if (prompt.includeAccessories) {
        const accessoryPool = accessories
            .filter(accessory => !requiredNames.has(normalizeText(accessory.name)))
            .sort((left, right) => accessorySuitability(right, intent) - accessorySuitability(left, intent))
            .slice(0, 4);
        const baseCandidates = candidates.slice(0, 120).filter(candidate => !candidate.items.some(isAccessory));
        for (const candidate of baseCandidates) {
            for (const accessory of accessoryPool.slice(0, intent.dressy ? 2 : 1)) {
                pushCandidate(candidates, [...candidate.items, accessory], prompt);
            }
        }
    }

    const recentNames = new Set(uniqueStrings(prompt.recentlyRecommendedGarments).map(normalizeText));
    const rotationCandidates = intent.surpriseMe && recentNames.size > 0
        ? candidates.filter(candidate => candidate.items.every(item => !recentNames.has(normalizeText(item.name))))
        : candidates;
    const candidatePool = rotationCandidates.length > 0 ? rotationCandidates : candidates;
    const scored = deduplicateCandidates(candidatePool).map(candidate => {
        let score = 0;
        const complete = isCompleteLook(candidate.items);
        score += complete ? 16 : -5;
        score += scoreColorHarmony(candidate.items);
        score += scoreSilhouette(candidate.items, profile);

        for (const item of candidate.items) {
            score += scoreItemForIntent(item, intent, weather);
            score += scoreOccasionMatch(item, intent);
            score += scoreColorPreference(item, prompt.colorPreferences, profile);
            score += scoreStyleProfile(item, profile);

            const isRequired = requiredNames.has(normalizeText(item.name));
            if (item.isFavorite) score += 1.5;
            score -= Math.min(8, Math.max(0, item.wearCount || 0) * 0.18);
            if (!isRequired && recentNames.has(normalizeText(item.name))) score -= 8;
            score -= recencyPenalty(item.lastWorn);
        }

        if (candidate.items.filter(isTop).length > 1) score -= 7;
        if (candidate.items.filter(isBottom).length > 1) score -= 7;
        if (candidate.items.length > 5) score -= (candidate.items.length - 5) * 2;
        if (requiredGarments.length > 0 && requiredGarments.every(required =>
            candidate.items.some(item => normalizeText(item.name) === normalizeText(required.name)))) {
            score += 20;
        }

        return { candidate, score, key: candidateKey(candidate) };
    });

    scored.sort((left, right) => right.score - left.score || left.key.localeCompare(right.key));

    // Keep the AI shortlist stylistically diverse. Without this step Gemini
    // tends to choose the first of several nearly identical permutations.
    const diverse: CandidateOutfit[] = [];
    for (const entry of scored) {
        if (diverse.every(existing => itemOverlap(existing, entry.candidate) < 0.9)) {
            diverse.push(entry.candidate);
        }
        if (diverse.length === 10) break;
    }
    if (diverse.length < 10) {
        for (const entry of scored) {
            if (!diverse.some(existing => candidateKey(existing) === entry.key)) diverse.push(entry.candidate);
            if (diverse.length === 10) break;
        }
    }
    return diverse;
}

function buildStyleIntent(prompt: OutfitPrompt): StyleIntent {
    const desiredFormalities = new Set<string>();
    const occasionTerms = new Set<string>();
    const preferredCategories = new Set<string>();
    let active = false;
    let dressy = false;
    const parsedFormalityLevel = typeof prompt.formalityLevel === 'number' && Number.isFinite(prompt.formalityLevel)
        ? Math.min(4, Math.max(0, Math.round(prompt.formalityLevel)))
        : null;
    const surpriseMe = splitPromptValues(prompt.occasion).some(occasion => normalizeText(occasion) === 'surprise me');

    const add = (terms: string[], formalities: string[], categories: string[] = []): void => {
        terms.forEach(term => occasionTerms.add(term));
        formalities.forEach(formality => desiredFormalities.add(formality));
        categories.forEach(category => preferredCategories.add(category));
    };

    const occasions = splitPromptValues(prompt.occasion);
    const meaningfulOccasions = occasions.filter(occasion => !['surprise me', 'no preference', 'automatic'].includes(normalizeText(occasion)));
    const requestedOccasions = meaningfulOccasions.length > 0 ? meaningfulOccasions : ['Everyday'];
    const hasSpecificContext = meaningfulOccasions.some(occasion => normalizeText(occasion) !== 'other') || stringValue(prompt.contextNote).length > 0;
    for (const occasion of requestedOccasions) {
        const value = normalizeText(occasion);
        if (value.includes('gym') || value.includes('active')) {
            active = true;
            add(['gym', 'active', 'sport'], ['Casual'], ['Activewear', 'Footwear']);
        }
        if (value.includes('special event') || value.includes('wedding')) {
            dressy = true;
            add(['wedding', 'formal', 'cocktail'], ['Formal', 'Cocktail', 'Business'], ['Formalwear', 'Footwear']);
        }
        if (value.includes('important meeting') || value.includes('business meeting')) {
            dressy = true;
            add(['business meeting', 'business', 'office'], ['Business', 'Formal'], ['Formalwear', 'Outerwear', 'Footwear']);
        }
        if (value.includes('work') || value.includes('office')) {
            dressy = true;
            add(['office', 'work', 'business casual'], ['Smart casual', 'Business'], ['Tops', 'Bottoms', 'Outerwear', 'Footwear']);
        }
        if (value.includes('university')) {
            add(['university', 'daily wear'], ['Casual', 'Smart casual'], ['Tops', 'Bottoms', 'Footwear']);
        }
        if (value.includes('social') || value.includes('dinner')) {
            dressy = true;
            add(['dinner', 'date', 'cocktail'], ['Smart casual', 'Cocktail', 'Formal'], ['Tops', 'Bottoms', 'Formalwear', 'Footwear']);
        }
        if (value.includes('party') || value.includes('night')) {
            dressy = true;
            add(['party', 'cocktail'], ['Cocktail', 'Smart casual', 'Formal'], ['Formalwear', 'Footwear']);
        }
        if (value.includes('date')) {
            dressy = true;
            add(['date', 'dinner'], ['Smart casual', 'Cocktail'], ['Tops', 'Bottoms', 'Footwear']);
        }
        if (value.includes('travel') || value.includes('vacation')) {
            add(['vacation', 'daily wear'], ['Casual', 'Smart casual'], ['Tops', 'Bottoms', 'Footwear']);
        }
        if (value.includes('everyday') || value.includes('daily')) {
            add(['daily wear', 'everyday'], ['Casual', 'Smart casual'], ['Tops', 'Bottoms', 'Footwear']);
        }
    }

    const contextNote = normalizeText(prompt.contextNote);
    if (contextNote) {
        if (/interview|presentation|client|meeting|work/.test(contextNote)) {
            dressy = true;
            add(['business', 'office', 'presentation'], ['Smart casual', 'Business', 'Formal'], ['Tops', 'Bottoms', 'Outerwear', 'Footwear']);
        }
        if (/dinner|date|restaurant|friends|social|party|night/.test(contextNote)) {
            dressy = true;
            add(['dinner', 'date', 'social'], ['Smart casual', 'Cocktail'], ['Tops', 'Bottoms', 'Formalwear', 'Footwear']);
        }
        if (/gym|run|sport|training|exercise/.test(contextNote)) {
            active = true;
            add(['gym', 'sport', 'active'], ['Casual'], ['Activewear', 'Footwear']);
        }
        if (/comfortable|comfort|relaxed|casual/.test(contextNote)) {
            add(['everyday', 'casual'], ['Casual', 'Smart casual'], ['Tops', 'Bottoms', 'Footwear']);
        }
    }

    if (meaningfulOccasions.length === 0 && !contextNote) {
        add(['everyday'], ['Casual', 'Smart casual'], ['Tops', 'Bottoms', 'Footwear']);
    }

    const dressCodes = splitPromptValues(prompt.dressCode);
    // Keep this branch for older clients. Newer clients use the horizontal
    // formality scale below instead of sending a fixed dress-code list.
    if (dressCodes.length > 0 && parsedFormalityLevel === null) {
        desiredFormalities.clear();
        preferredCategories.clear();
    }
    for (const dressCode of dressCodes) {
        const value = normalizeText(dressCode);
        if (value.includes('business formal')) {
            dressy = true;
            add(['business formal'], ['Business', 'Formal'], ['Formalwear', 'Outerwear', 'Footwear']);
        } else if (value.includes('business casual')) {
            dressy = true;
            add(['business casual'], ['Smart casual', 'Business'], ['Tops', 'Bottoms', 'Outerwear', 'Footwear']);
        } else if (value.includes('cocktail')) {
            dressy = true;
            add(['cocktail'], ['Cocktail', 'Formal'], ['Formalwear', 'Footwear']);
        } else if (value.includes('smart casual')) {
            add(['smart casual'], ['Smart casual', 'Casual'], ['Tops', 'Bottoms', 'Footwear']);
        } else if (value.includes('casual')) {
            add(['casual'], ['Casual'], ['Tops', 'Bottoms', 'Footwear']);
        }
    }

    if (parsedFormalityLevel !== null) {
        desiredFormalities.clear();
        desiredFormalitiesForLevel(parsedFormalityLevel).forEach(formality => desiredFormalities.add(formality));
    }

    const weather = parseWeatherIntent(prompt.weather, null);
    const effectiveDressy = dressy || (parsedFormalityLevel !== null && parsedFormalityLevel >= 3);
    return {
        desiredFormalities: [...desiredFormalities],
        occasionTerms: [...occasionTerms],
        preferredCategories: [...preferredCategories],
        formalityLevel: parsedFormalityLevel,
        hasSpecificContext,
        surpriseMe,
        active,
        dressy: effectiveDressy,
        shouldLayer: active ? false : weather.cold || weather.wet || (effectiveDressy && !weather.hot),
        avoidAccessories: active
    };
}

function desiredFormalitiesForLevel(level: number): string[] {
    switch (Math.min(4, Math.max(0, level))) {
    case 0: return ['Casual'];
    case 1: return ['Casual', 'Smart casual'];
    case 2: return ['Smart casual', 'Business'];
    case 3: return ['Business', 'Cocktail', 'Formal'];
    default: return ['Formal', 'Cocktail', 'Business'];
    }
}

function parseWeatherIntent(weatherText: string, profile: UserProfileSummary | null): WeatherIntent {
    const text = normalizeText(weatherText);
    const match = text.match(/(-?\d+(?:\.\d+)?)\s*°?\s*([fc])?/i);
    let temperatureF: number | null = null;
    if (match?.[1]) {
        const value = Number(match[1]);
        temperatureF = match[2]?.toLowerCase() === 'c' ? (value * 9 / 5) + 32 : value;
    }
    const cold = Boolean(temperatureF !== null && temperatureF <= 60) || /cold|chilly|snow|freez/.test(text);
    const hot = Boolean(temperatureF !== null && temperatureF >= 80) || /hot|heat|scorch/.test(text);
    const wet = /rain|storm|snow|wet/.test(text);
    let targetWarmth = cold ? 3 : hot ? 1 : 2;
    const comfort = normalizeText(profile?.climateComfort);
    if (comfort.includes('run hot')) targetWarmth = Math.max(1, targetWarmth - 1);
    if (comfort.includes('run cold')) targetWarmth = Math.min(3, targetWarmth + 1);
    return { cold, hot, wet, targetWarmth };
}

function scoreItemForIntent(item: GarmentSummary, intent: StyleIntent, weather: WeatherIntent): number {
    const category = normalizeText(item.category);
    const formality = normalizeText(item.formality);
    const material = normalizeText(item.material);
    const subcategory = normalizeText(item.subcategory);
    let score = 0;

    if (intent.preferredCategories.some(value => normalizeText(value) === category)) score += 3;
    if (intent.formalityLevel !== null) {
        const distance = Math.abs(formalityLevelForValue(formality) - intent.formalityLevel);
        score += Math.max(-12, 20 - distance * 8);
    } else {
        const desiredFormalities = intent.desiredFormalities.map(normalizeText);
        if (desiredFormalities.includes(formality)) score += 10;
        else if (intent.dressy && ['casual', 'smart casual'].includes(formality)) score -= 8;
        else if (desiredFormalities.length > 0) score -= 2;
    }
    if (intent.active) {
        if (category === 'activewear') score += 12;
        else if (isActiveCompatible(item)) score += 7;
        if (material === 'technical' || material === 'synthetic') score += 3;
        if (subcategory === 'sneaker' || subcategory === 'shoes') score += 3;
        if (!isActiveCompatible(item) && !isFootwear(item)) score -= 8;
        if (['business', 'cocktail', 'formal'].includes(formality)) score -= 10;
    }

    if (intent.dressy && ['casual', 'smart casual'].includes(formality)) score -= 2;
    if (weather.hot && item.warmth >= 3) score -= 7;
    if (weather.cold && item.warmth === 1 && !isAccessory(item)) score -= 4;
    if (weather.wet && ['leather', 'synthetic', 'technical'].includes(material)) score += 2;
    score += Math.max(-4, 4 - Math.abs((item.warmth || 2) - weather.targetWarmth) * 3);

    if (intent.dressy && (subcategory === 'loafer' || subcategory === 'blazer' || subcategory === 'tie')) score += 3;
    if (!intent.dressy && (subcategory === 'sneaker' || formality === 'casual')) score += 2;
    return score;
}

function scoreOccasionMatch(item: GarmentSummary, intent: StyleIntent): number {
    if (!intent.hasSpecificContext) return 0;
    const occasions = Array.isArray(item.occasions) ? item.occasions.map(normalizeText) : [];
    if (occasions.length === 0) return 0;
    const matched = intent.occasionTerms.some(term => occasions.some(occasion =>
        occasion === normalizeText(term) || occasion.includes(normalizeText(term)) || normalizeText(term).includes(occasion)
    ));
    if (intent.formalityLevel !== null) return matched ? 4 : -1;
    return matched ? 7 : -3;
}

function formalityLevelForValue(value: string): number {
    const normalized = normalizeText(value);
    if (normalized.includes('formal')) return 4;
    if (normalized.includes('cocktail')) return 3;
    if (normalized.includes('business')) return 2;
    if (normalized.includes('smart')) return 1;
    return 0;
}

function scoreColorPreference(item: GarmentSummary, preference: string, profile: UserProfileSummary | null): number {
    const text = normalizeText(preference);
    const primary = normalizeText(item.primaryColor);
    const secondary = (item.secondaryColors ?? []).map(normalizeText);
    let score = text && (text.includes(primary) || secondary.some(color => text.includes(color))) ? 5 : 0;
    const neutralPreferences = profile?.neutralColorPreferences ?? [];
    if (neutralPreferences.some(value => colorPreferenceMatches(value, primary))) score += 1.5;
    return score;
}

function scoreStyleProfile(item: GarmentSummary, profile: UserProfileSummary | null): number {
    if (!profile) return 0;
    const archetypes = (profile.coreStyleArchetypes ?? []).map(normalizeText);
    const color = normalizeText(item.primaryColor);
    const material = normalizeText(item.material);
    const fit = normalizeText(item.fit);
    const pattern = normalizeText(item.pattern);
    return archetypes.reduce((score, archetype) => {
        if (archetype.includes('minimal') && pattern === 'solid' && isNeutralColor(color)) return score + 3;
        if (archetype.includes('streetwear') && (fit === 'oversized' || normalizeText(item.subcategory) === 'sneaker')) return score + 3;
        if (archetype.includes('classic') && (fit === 'tailored' || ['loafer', 'blazer'].includes(normalizeText(item.subcategory)))) return score + 3;
        if (archetype.includes('trendy') && (fit === 'cropped' || fit === 'wide-leg' || pattern === 'print')) return score + 2;
        if (archetype.includes('boho') && (material === 'linen' || pattern === 'floral' || ['brown', 'beige', 'camel'].includes(color))) return score + 2;
        if (archetype.includes('edgy') && (color === 'black' || material === 'leather')) return score + 3;
        return score;
    }, 0);
}

function scoreColorHarmony(items: GarmentSummary[]): number {
    const colorsInLook = items.map(item => normalizeText(item.primaryColor)).filter(Boolean);
    let score = 0;
    for (let index = 0; index < colorsInLook.length; index += 1) {
        for (let other = index + 1; other < colorsInLook.length; other += 1) {
            const first = colorsInLook[index]!;
            const second = colorsInLook[other]!;
            if (first === second) score += 1;
            else if (isNeutralColor(first) && isNeutralColor(second)) score += 2;
            else if (areKnownColorPair(first, second)) score += 3;
            else score -= 1;
        }
    }
    return score;
}

function scoreSilhouette(items: GarmentSummary[], profile: UserProfileSummary | null): number {
    const topsInLook = items.filter(isTop);
    const bottomsInLook = items.filter(isBottom);
    if (topsInLook.length === 0 || bottomsInLook.length === 0) return 0;
    const topFit = normalizeText(topsInLook[0]?.fit);
    const bottomFit = normalizeText(bottomsInLook[0]?.fit);
    let score = topFit === 'oversized' && bottomFit === 'wide-leg' ? -2 : 1;
    if (topFit === 'oversized' && ['slim', 'tailored'].includes(bottomFit)) score += 3;
    if (bottomFit === 'wide-leg' && ['slim', 'cropped', 'fitted'].includes(topFit)) score += 3;
    if (profile && normalizeText(profile.fitSilhouette).includes(topFit)) score += 2;
    return score;
}

function recencyPenalty(lastWorn: string | null): number {
    if (!lastWorn) return 0;
    const timestamp = Date.parse(lastWorn);
    if (!Number.isFinite(timestamp)) return 0;
    const days = Math.max(0, (Date.now() - timestamp) / 86_400_000);
    if (days < 1) return 8;
    if (days < 2) return 5;
    if (days < 4) return 2;
    return 0;
}

function pushCandidate(candidates: CandidateOutfit[], items: GarmentSummary[], prompt: OutfitPrompt): void {
    const uniqueItems = items.filter((item, index, all) => all.findIndex(other => normalizeText(other.name) === normalizeText(item.name)) === index);
    candidates.push({ items: uniqueItems, missingPieces: buildMissingPieces(uniqueItems, prompt) });
}

function pushRequiredItems(candidate: CandidateOutfit, required: GarmentSummary[], prompt: OutfitPrompt): CandidateOutfit {
    const items = [...candidate.items];
    for (const garment of required) {
        if (!items.some(item => normalizeText(item.name) === normalizeText(garment.name))) items.push(garment);
    }
    return { items, missingPieces: buildMissingPieces(items, prompt) };
}

function buildMissingPieces(items: GarmentSummary[], prompt: OutfitPrompt): string[] {
    if (isCompleteLook(items)) return [];
    const preferredColor = firstColorPreference(prompt.colorPreferences) || 'neutral';
    const missing: string[] = [];
    if (!items.some(isDress) && !items.some(isTop)) missing.push(`${preferredColor} top`);
    if (!items.some(isDress) && !items.some(isBottom)) missing.push(`${preferredColor} bottom`);
    if (!items.some(isDress) && !items.some(isFootwear)) missing.push(`${preferredColor} shoes`);
    return missing.length > 0 ? missing : [`${preferredColor} complementary piece`];
}

function isCompleteLook(items: GarmentSummary[]): boolean {
    return items.some(isDress) ? items.some(isFootwear) : items.some(isTop) && items.some(isBottom) && items.some(isFootwear);
}

function deduplicateCandidates(candidates: CandidateOutfit[]): CandidateOutfit[] {
    const seen = new Set<string>();
    return candidates.filter(candidate => {
        const key = candidateKey(candidate);
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
    });
}

function candidateKey(candidate: CandidateOutfit): string {
    return candidate.items.map(item => normalizeText(item.name)).sort().join('|');
}

function itemOverlap(left: CandidateOutfit, right: CandidateOutfit): number {
    const rightNames = new Set(right.items.map(item => normalizeText(item.name)));
    const overlap = left.items.filter(item => rightNames.has(normalizeText(item.name))).length;
    return overlap / Math.max(1, Math.min(left.items.length, right.items.length));
}

function accessorySuitability(item: GarmentSummary, intent: StyleIntent): number {
    const subcategory = normalizeText(item.subcategory);
    if (intent.dressy && subcategory === 'tie') return 5;
    if (['belt', 'bag'].includes(subcategory)) return 3;
    return 1;
}

function splitPromptValues(value: string): string[] {
    return uniqueStrings(value.split(/,|\||;/).map(part => part.trim()));
}

function normalizeOutfitPrompt(prompt: OutfitPrompt): OutfitPrompt {
    return {
        ...prompt,
        // The client limits this to two, but enforce the same contract for
        // older clients and direct API callers.
        occasion: splitPromptValues(stringValue(prompt.occasion)).slice(0, 2).join(', '),
        includeAccessories: prompt.includeAccessories === true
    };
}

function normalizeText(value: unknown): string {
    return stringValue(value).toLocaleLowerCase().replace(/[–—]/g, '-').trim();
}

function isTop(item: GarmentSummary): boolean {
    return normalizeText(item.category) === 'tops' || ['shirt'].includes(normalizeText(item.subcategory));
}

function isBottom(item: GarmentSummary): boolean {
    return normalizeText(item.category) === 'bottoms' || ['jeans', 'trouser'].includes(normalizeText(item.subcategory));
}

function isFootwear(item: GarmentSummary): boolean {
    return normalizeText(item.category) === 'footwear' || ['shoes', 'sneaker', 'loafer'].includes(normalizeText(item.subcategory));
}

function isDress(item: GarmentSummary): boolean {
    return normalizeText(item.subcategory) === 'dress';
}

function isOuterwear(item: GarmentSummary): boolean {
    return normalizeText(item.category) === 'outerwear' || ['coat', 'blazer'].includes(normalizeText(item.subcategory));
}

function isAccessory(item: GarmentSummary): boolean {
    return normalizeText(item.category) === 'accessories' || ['accessory', 'bag', 'belt', 'tie'].includes(normalizeText(item.subcategory));
}

function isActiveCompatible(item: GarmentSummary): boolean {
    const category = normalizeText(item.category);
    const material = normalizeText(item.material);
    const occasions = (item.occasions ?? []).map(normalizeText);
    return category === 'activewear' || material === 'technical' || material === 'synthetic' || occasions.some(occasion => occasion.includes('gym') || occasion.includes('sport'));
}

function isNeutralColor(color: string): boolean {
    return ['black', 'white', 'ivory', 'cream', 'gray', 'navy', 'blue', 'camel', 'brown', 'beige'].includes(normalizeText(color));
}

function areKnownColorPair(first: string, second: string): boolean {
    const pair = [normalizeText(first), normalizeText(second)].sort().join('|');
    return new Set(['beige|blue', 'beige|brown', 'beige|navy', 'black|white', 'blue|white', 'brown|cream', 'camel|navy', 'gray|pink', 'green|ivory', 'navy|white']).has(pair);
}

function colorPreferenceMatches(preference: string, color: string): boolean {
    const value = normalizeText(preference);
    if (value.includes('black') || value.includes('dark gray')) return ['black', 'gray'].includes(color);
    if (value.includes('white') || value.includes('light gray')) return ['white', 'ivory', 'cream', 'gray'].includes(color);
    if (value.includes('navy') || value.includes('blue')) return ['navy', 'blue'].includes(color);
    if (value.includes('beige') || value.includes('brown') || value.includes('cream')) return ['beige', 'brown', 'camel', 'cream'].includes(color);
    return value.includes(color);
}

function firstColorPreference(preference: string): string | null {
    const normalized = normalizeText(preference);
    const option = colors.find(color => normalized.includes(normalizeText(color)));
    return option?.toLocaleLowerCase() ?? null;
}

app.post('/ai/outfit-recommendation', requireAuth, async (request: Request, response: Response): Promise<void> => {
    if (!allowAIRequest(request, response)) return;
    const rawPrompt = objectValue(request.body?.prompt);
    const garments = Array.isArray(request.body?.garments) ? request.body.garments as GarmentSummary[] : [];
    const profile = objectValue(request.body?.profile) as unknown as UserProfileSummary | null;

    if (!rawPrompt) {
        response.status(400).json({ error: 'A prompt configuration is required.' });
        return;
    }

    if (garments.length > 250) {
        response.status(413).json({ error: 'The wardrobe request is too large.' });
        return;
    }

    const prompt = normalizeOutfitPrompt(rawPrompt as unknown as OutfitPrompt);

    const shortlist = generateShortlist(prompt, garments, profile);

    if (shortlist.length === 0 || !geminiAPIKey) {
        const draft = makeOutfitDraft(prompt, garments, profile);
        response.json({ draft });
        return;
    }

    try {
        const draft = await recommendWithGemini(prompt, profile, shortlist);
        response.json({ draft });
    } catch (error) {
        console.error('Gemini outfit recommendation failed:', error);
        // Clean fallback
        const draft = makeOutfitDraft(prompt, garments, profile);
        response.json({ draft, warning: 'Gemini styled draft was unavailable; local deterministic fallback used.' });
    }
});

async function recommendWithGemini(
    prompt: OutfitPrompt,
    profile: UserProfileSummary | null,
    shortlist: CandidateOutfit[]
): Promise<OutfitDraft> {
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(geminiModel)}:generateContent`;

    const formattedShortlist = shortlist.map((candidate, index) => {
        return `Candidate ${index}:\nItems:\n${candidate.items.map(item => `- Name: ${item.name}, Category: ${item.category}, Subcategory: ${item.subcategory}, Color: ${item.primaryColor}, Formality: ${item.formality}, Warmth: ${item.warmth}, Material: ${item.material}, Fit: ${item.fit}, Occasions: ${(item.occasions ?? []).join(', ') || 'Not specified'}`).join('\n')}\nMissing: ${candidate.missingPieces.join(', ') || 'None'}`;
    }).join('\n\n');

    const systemPrompt = `You are Apparelgio, an expert personal stylist. Your task is to select the single best outfit candidate from the shortlist provided.
You MUST choose exactly one candidate index. Do not combine items from different candidates, invent new garments, or suggest items the user does not own (other than the listed Missing Pieces).

Current Context:
- Requested Occasion: ${prompt.occasion || 'Everyday'}
- Additional Context: ${prompt.contextNote || 'None'}
- Formality Preference: ${formalityLabel(prompt.formalityLevel)}
- Include Optional Accessories: ${prompt.includeAccessories ? 'Yes' : 'No'}
- Weather Context: ${prompt.weather || 'Weather unavailable'}
- Color Preference: ${prompt.colorPreferences || 'Closet palette'}
- Garments recently recommended in this session: ${prompt.recentlyRecommendedGarments?.join(', ') || 'None'}

User Profile Preferences:
${profile ? `- Name: ${profile.displayName || 'Not provided'}
- Gender: ${profile.gender || 'Not provided'}
- Age: ${profile.age ?? 'Not provided'}
- Core Archetypes: ${profile.coreStyleArchetypes.join(', ')}
- Neutral Colors: ${profile.neutralColorPreferences.join(', ')}
- Fit Preference: ${profile.fitSilhouette}
- Climate Comfort: ${profile.climateComfort}` : 'No profile preferences set.'}

Available Candidates:
${formattedShortlist}

Instructions:
1. Select the single best outfit candidate.
2. Formulate a structured JSON response matching the required schema.
3. Treat explicit required and excluded garments as hard constraints. Treat occasion, formality, weather, color, and profile preferences as weighted priorities.
4. Respect the formality preference as a horizontal spectrum: use the nearest suitable level rather than rejecting the wardrobe when an exact level is unavailable.
5. A gym request should strongly prefer activewear, but an incomplete active wardrobe should produce a transparent partial look instead of unrelated formal clothing.
6. Prefer candidates with appropriate warmth, coherent colors, balanced proportions, and relevant garment occasions. Do not choose a candidate only because it appears first.
7. Avoid recently recommended garments when another suitable candidate exists. Do not invent clothing, merge candidates, or add items outside the selected candidate.
8. Keep the language tone polished and refined for elevated requests, but practical, clean, and direct for everyday, active, or travel requests.
9. Provide highly specific practical styling advice in the rationale (e.g., "tuck the shirt in lightly", "leave the blazer unbuttoned for a relaxed look").`;

    const response = await fetch(endpoint, {
        method: 'POST',
        signal: AbortSignal.timeout(geminiRequestTimeoutMs),
        headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': geminiAPIKey
        },
        body: JSON.stringify({
            contents: [{
                parts: [{ text: systemPrompt }]
            }],
            generationConfig: {
                temperature: 0.3,
                responseMimeType: 'application/json',
                responseSchema: {
                    type: 'OBJECT',
                    properties: {
                        title: { type: 'STRING', description: 'A creative title for this selected outfit combination.' },
                        candidateIndex: { type: 'INTEGER', description: 'The chosen candidate index (from the list of candidates).' },
                        rationale: { type: 'STRING', description: 'A concise explanation of why the selected candidate works.' },
                        weatherNote: { type: 'STRING', description: 'A short note explaining the outfit in today weather.' },
                        colorExplanation: { type: 'STRING', description: 'A short explanation of the color combination.' },
                        stylingInstructions: { type: 'STRING', description: 'Practical instructions such as tucking in a shirt or leaving a blazer open.' }
                    },
                    required: ['title', 'candidateIndex', 'rationale', 'weatherNote', 'colorExplanation', 'stylingInstructions']
                }
            }
        })
    });

    if (!response.ok) {
        throw new Error(`Gemini returned HTTP ${response.status}.`);
    }

    const payload = await response.json() as GeminiGenerateContentResponse;
    const content = payload.candidates?.[0]?.content?.parts
        ?.map(part => part.text ?? '')
        .join('') ?? '';

    const result = parseJSONObject(content);
    const chosenIndex = boundedNumber(result.candidateIndex, 0, shortlist.length - 1, 0);
    const selectedCandidate = shortlist[chosenIndex]!;

    return {
        title: stringValue(result.title, 'The Curated Edit'),
        occasion: stringValue(prompt.occasion, 'Everyday'),
        weather: stringValue(prompt.weather, 'Weather context'),
        dressCode: formalityLabel(prompt.formalityLevel, prompt.dressCode),
        itemNames: selectedCandidate.items.map(item => item.name),
        missingPieces: selectedCandidate.missingPieces,
        rationale: stringValue(result.rationale, 'This combination was selected from your wardrobe to best coordinate with your style and today\'s event.'),
        weatherNote: stringValue(result.weatherNote, 'This outfit considers today weather context.'),
        colorExplanation: stringValue(result.colorExplanation, 'The selected colors create a cohesive look.'),
        stylingInstructions: stringValue(result.stylingInstructions, 'Adjust the fit for comfort and the occasion.')
    };
}

app.use((error: unknown, _request: Request, response: Response, _next: NextFunction) => {
    if (error instanceof multer.MulterError) {
        response.status(400).json({ error: `Image upload failed: ${error.message}` });
        return;
    }

    if (error instanceof Error) {
        const message = process.env.NODE_ENV === 'production'
            ? 'The request could not be processed.'
            : error.message;
        response.status(400).json({ error: message });
        return;
    }

    response.status(500).json({ error: 'Unexpected server error.' });
});

if (process.env.NODE_ENV !== 'test') {
    const server = app.listen(port, () => {
        console.log(`Apparelgio backend listening on port ${port}.`);
    });
    // Gemini retries can take up to roughly 41 seconds. Keep the HTTP server
    // alive long enough for the client to receive the deterministic fallback.
    server.requestTimeout = 60_000;
    server.headersTimeout = 65_000;
    server.keepAliveTimeout = 5_000;

    const shutdown = (signal: string) => {
        console.log(`Received ${signal}; closing the backend.`);
        server.close(error => {
            if (error) {
                console.error('Backend shutdown failed:', error);
                process.exitCode = 1;
            }
        });
    };

    process.once('SIGTERM', () => shutdown('SIGTERM'));
    process.once('SIGINT', () => shutdown('SIGINT'));
}

export { generateShortlist };

async function analyzeWithGemini(image: Buffer): Promise<Record<string, unknown>> {
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(geminiModel)}:generateContent`;
    const payload = await requestGeminiContent(endpoint, {
        contents: [{
            parts: [
                { text: garmentAnalysisPrompt },
                {
                    inline_data: {
                        mime_type: 'image/jpeg',
                        data: image.toString('base64')
                    }
                }
            ]
        }],
        generationConfig: {
            temperature: 0.1,
            responseMimeType: 'application/json'
        }
    });
    const content = payload.candidates?.[0]?.content?.parts
        ?.map(part => part.text ?? '')
        .join('') ?? '';
    return parseJSONObject(content);
}

async function requestGeminiContent(endpoint: string, body: Record<string, unknown>): Promise<GeminiGenerateContentResponse> {
    let lastError: unknown = new Error('Gemini request failed.');

    for (let attempt = 1; attempt <= geminiMaxAttempts; attempt += 1) {
        try {
            const response = await fetch(endpoint, {
                method: 'POST',
                signal: AbortSignal.timeout(geminiRequestTimeoutMs),
                headers: {
                    'Content-Type': 'application/json',
                    'x-goog-api-key': geminiAPIKey
                },
                body: JSON.stringify(body)
            });

            if (response.ok) {
                return await response.json() as GeminiGenerateContentResponse;
            }

            const error = new Error(`Gemini returned HTTP ${response.status}.`);
            lastError = error;
            if (!isRetryableGeminiStatus(response.status) || attempt >= geminiMaxAttempts) {
                throw error;
            }

            await new Promise(resolve => setTimeout(resolve, geminiRetryDelayMs * attempt));
            continue;
        } catch (error) {
            lastError = error;
            if (!isRetryableGeminiError(error) || attempt >= geminiMaxAttempts) {
                throw error;
            }

            await new Promise(resolve => setTimeout(resolve, geminiRetryDelayMs * attempt));
        }
    }

    throw lastError;
}

function isRetryableGeminiStatus(status: number): boolean {
    return status === 408 || status === 429 || status >= 500;
}

function isRetryableGeminiError(error: unknown): boolean {
    if (!(error instanceof Error)) return false;
    return error.name === 'TimeoutError'
        || error.name === 'AbortError'
        || error.message.includes('fetch failed');
}

const garmentAnalysisPrompt = `Analyze one clothing garment image. Return only a JSON object, with no markdown.
Use exactly these enum values:
- category: Tops, Bottoms, Outerwear, Footwear, Accessories, Formalwear, Activewear
- subcategory: Shirt, Blazer, Jeans, Dress, Shoes, Coat, Accessory, Trouser, Sneaker, Loafer, Bag, Belt, Tie
- formality: Casual, Smart casual, Business, Cocktail, Formal
- fit: Slim, Relaxed, Oversized, Tailored, Cropped, Wide-leg, Structured
- material: Cotton, Wool, Denim, Silk, Leather, Linen, Knit, Synthetic, Cashmere, Technical
- pattern: Solid, Striped, Floral, Checked, Ribbed, Satin, Textured, Print
- laundryStatus: Ready, Worn once, Laundry, Dry clean, Repair
Return name, category, subcategory, primaryColor, secondaryColors, formality, fit, warmth (1-3), material, pattern, occasions, brand, condition, laundryStatus, and confidence (0-1).`;

interface GeminiGenerateContentResponse {
    candidates?: Array<{
        content?: {
            parts?: Array<{ text?: string }>;
        };
    }>;
}

function fallbackGarmentResult(source: string): GarmentAnalysisResult {
    const isCamera = source.toLowerCase() === 'camera';
    return {
        name: isCamera ? 'New Camera Garment' : 'New Imported Garment',
        category: 'Tops',
        subcategory: 'Shirt',
        primaryColor: 'Black',
        secondaryColors: [],
        formality: 'Casual',
        fit: 'Relaxed',
        warmth: 2,
        material: 'Cotton',
        pattern: 'Solid',
        occasions: [],
        brand: 'Unspecified',
        condition: 'Excellent',
        laundryStatus: 'Ready',
        imageToken: 'server-analysis',
        confidence: 0
    };
}

function normalizeGarmentResult(value: Record<string, unknown>, fallback: GarmentAnalysisResult): GarmentAnalysisResult {
    const subcategory = canonical(value.subcategory, garmentTypes, fallback.subcategory);
    const fallbackCategory = categoryForGarmentType(subcategory);
    const primaryColor = canonical(value.primaryColor, colors, fallback.primaryColor);
    const secondaryColors = uniqueStrings(value.secondaryColors)
        .map(color => matchingOption(color, colors))
        .filter((color): color is WardrobeColor => color !== undefined && color !== primaryColor)
        .slice(0, 4);

    return {
        name: stringValue(value.name, fallback.name).slice(0, 80),
        category: canonical(value.category, garmentCategories, fallbackCategory),
        subcategory,
        primaryColor,
        secondaryColors,
        formality: normalizeFormality(value.formality),
        fit: canonical(value.fit, fits, fallback.fit),
        warmth: boundedNumber(value.warmth, 1, 3, fallback.warmth),
        material: canonical(value.material, materials, fallback.material),
        pattern: canonical(value.pattern, patterns, fallback.pattern),
        occasions: uniqueStrings(value.occasions).slice(0, 6),
        brand: stringValue(value.brand, fallback.brand).slice(0, 80),
        condition: stringValue(value.condition, fallback.condition).slice(0, 40),
        laundryStatus: canonical(value.laundryStatus, laundryStates, fallback.laundryStatus),
        imageToken: fallback.imageToken,
        confidence: boundedNumber(value.confidence, 0, 1, 0)
    };
}

function makeOutfitDraft(prompt: OutfitPrompt, rawGarments: GarmentSummary[], profile: UserProfileSummary | null): OutfitDraft {
    const occasion = stringValue(prompt.occasion, 'Everyday');
    const weather = stringValue(prompt.weather, 'Weather unavailable');
    const dressCode = formalityLabel(prompt.formalityLevel, prompt.dressCode);
    const colorPreferences = stringValue(prompt.colorPreferences, 'your closet palette');
    const shortlist = generateShortlist(prompt, rawGarments, profile);
    const selectedCandidate = shortlist[0];
    const itemNames = selectedCandidate?.items.map(item => item.name) ?? [];
    const missingPieces = selectedCandidate?.missingPieces ?? ['A top', 'A bottom', 'Shoes'];
    const styleLanguage = buildStyleLanguage(prompt, selectedCandidate?.items ?? []);

    return {
        title: itemNames.length === 0 ? 'Build Your First Look' : `${occasion} Edit`,
        occasion,
        weather,
        dressCode,
        itemNames: itemNames.length === 0 ? ['Add garments to unlock a full outfit'] : itemNames,
        missingPieces,
        rationale: selectedCandidate
            ? `This edit was selected for ${occasion.toLowerCase()} with ${dressCode.toLowerCase()} priorities. ${styleLanguage}`
            : `No compatible complete look was found for ${occasion.toLowerCase()}. Add the missing pieces to unlock a full recommendation.`,
        weatherNote: `Weather context: ${weather}. The selected warmth and layering reflect today's conditions.`,
        colorExplanation: `Color direction: ${colorPreferences}. The recommendation prioritizes a cohesive palette from the available closet.`,
        stylingInstructions: selectedCandidate ? 'Balance the silhouette, keep the most structured layer visible, and adjust the fit for comfort.' : 'Add clean, available pieces before generating another look.'
    };
}

function formalityLabel(level: number | null | undefined, legacyDressCode = ''): string {
    if (typeof level === 'number' && Number.isFinite(level)) {
        return ['Relaxed', 'Smart casual', 'Polished', 'Elevated', 'Formal'][Math.min(4, Math.max(0, Math.round(level)))] ?? 'Automatic';
    }
    return stringValue(legacyDressCode, 'Automatic');
}

function buildStyleLanguage(prompt: OutfitPrompt, items: GarmentSummary[]): string {
    const colorsInLook = uniqueStrings(items.map(item => item.primaryColor));
    const layers = items.filter(isOuterwear).length > 0 ? 'The outer layer gives the look a deliberate finish.' : 'The base layers keep the outfit coherent and easy to wear.';
    return `${layers} The palette centers on ${colorsInLook.join(' and ') || 'your wardrobe neutrals'}.`;
}

function parseJSONObject(content: string): Record<string, unknown> {
    const trimmed = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
    const start = trimmed.indexOf('{');
    const end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
        throw new Error('AI response did not contain a JSON object.');
    }

    return objectValue(JSON.parse(trimmed.slice(start, end + 1))) ?? {};
}

function canonical<T extends readonly string[]>(value: unknown, options: T, fallback: T[number]): T[number] {
    return matchingOption(value, options) ?? fallback;
}

function matchingOption<T extends readonly string[]>(value: unknown, options: T): T[number] | undefined {
    const normalized = stringValue(value).toLocaleLowerCase();
    return options.find(option => option.toLocaleLowerCase() === normalized);
}

function normalizeFormality(value: unknown): Formality {
    const normalized = stringValue(value).toLocaleLowerCase();
    if (normalized.includes('business')) return 'Business';
    return canonical(value, formalities, 'Casual') as Formality;
}

function categoryForGarmentType(type: GarmentType): GarmentCategory {
    const categories: Record<GarmentType, GarmentCategory> = {
        Shirt: 'Tops', Blazer: 'Outerwear', Jeans: 'Bottoms', Dress: 'Formalwear',
        Shoes: 'Footwear', Coat: 'Outerwear', Accessory: 'Accessories', Trouser: 'Bottoms',
        Sneaker: 'Footwear', Loafer: 'Footwear', Bag: 'Accessories', Belt: 'Accessories', Tie: 'Accessories'
    };
    return categories[type];
}

function stringValue(value: unknown, fallback = ''): string {
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : fallback;
}

function uniqueStrings(value: unknown): string[] {
    if (!Array.isArray(value)) return [];
    const seen = new Set<string>();
    return value.reduce<string[]>((result, item) => {
        const normalized = stringValue(item);
        const key = normalized.toLocaleLowerCase();
        if (normalized && !seen.has(key)) {
            seen.add(key);
            result.push(normalized);
        }
        return result;
    }, []);
}

function boundedNumber(value: unknown, min: number, max: number, fallback: number): number {
    return typeof value === 'number' && Number.isFinite(value) ? Math.min(Math.max(Math.round(value), min), max) : fallback;
}

function objectValue(value: unknown): Record<string, unknown> | null {
    return typeof value === 'object' && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : null;
}
