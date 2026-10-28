import assert from 'node:assert/strict';
import test from 'node:test';
import { generateShortlist, type GarmentSummary, type OutfitPrompt } from './index.js';

const basePrompt: OutfitPrompt = {
    weather: 'Mild, 68°F',
    occasion: 'Daily wear',
    dressCode: '',
    colorPreferences: '',
    timeAvailable: '10 minutes',
    laundry: '',
    favorites: '',
    specificRequirements: [],
    excludedGarments: [],
    recentlyRecommendedGarments: []
};

function prompt(overrides: Partial<OutfitPrompt> = {}): OutfitPrompt {
    return { ...basePrompt, ...overrides };
}

function garment(
    name: string,
    values: Partial<GarmentSummary> & Pick<GarmentSummary, 'category' | 'subcategory' | 'formality' | 'fit' | 'material' | 'primaryColor' | 'warmth' | 'occasions'>
): GarmentSummary {
    const defaults: GarmentSummary = {
        name,
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
        laundryStatus: 'Ready',
        isFavorite: false,
        wearCount: 0,
        lastWorn: null
    };
    return Object.assign(defaults, values);
}

const whiteOxford = garment('White Oxford Shirt', {
    category: 'Tops', subcategory: 'Shirt', primaryColor: 'White', formality: 'Business',
    fit: 'Tailored', warmth: 1, material: 'Cotton', occasions: ['Office', 'Business meeting', 'Wedding']
});
const blackBlazer = garment('Black Blazer', {
    category: 'Outerwear', subcategory: 'Blazer', primaryColor: 'Black', formality: 'Business',
    fit: 'Tailored', warmth: 2, material: 'Wool', occasions: ['Office', 'Business meeting', 'Wedding']
});
const navyTrousers = garment('Navy Trousers', {
    category: 'Bottoms', subcategory: 'Trouser', primaryColor: 'Navy', formality: 'Business',
    fit: 'Tailored', warmth: 2, material: 'Wool', occasions: ['Office', 'Business meeting', 'Wedding']
});
const brownLoafers = garment('Brown Loafers', {
    category: 'Footwear', subcategory: 'Loafer', primaryColor: 'Brown', formality: 'Business',
    fit: 'Structured', warmth: 1, material: 'Leather', occasions: ['Office', 'Business meeting', 'Wedding']
});
const blackTee = garment('Black T-Shirt', {
    category: 'Tops', subcategory: 'Shirt', primaryColor: 'Black', formality: 'Casual',
    fit: 'Relaxed', warmth: 1, material: 'Cotton', occasions: ['Daily wear', 'University']
});
const blueJeans = garment('Blue Jeans', {
    category: 'Bottoms', subcategory: 'Jeans', primaryColor: 'Blue', formality: 'Casual',
    fit: 'Relaxed', warmth: 2, material: 'Denim', occasions: ['Daily wear', 'University']
});
const whiteSneakers = garment('White Sneakers', {
    category: 'Footwear', subcategory: 'Sneaker', primaryColor: 'White', formality: 'Casual',
    fit: 'Relaxed', warmth: 1, material: 'Leather', occasions: ['Daily wear', 'University']
});
const blackTrainingTee = garment('Black Training Tee', {
    category: 'Activewear', subcategory: 'Shirt', primaryColor: 'Black', formality: 'Casual',
    fit: 'Relaxed', warmth: 1, material: 'Technical', occasions: ['Gym']
});
const runningShoes = garment('Running Shoes', {
    category: 'Footwear', subcategory: 'Sneaker', primaryColor: 'Red', formality: 'Casual',
    fit: 'Structured', warmth: 1, material: 'Synthetic', occasions: ['Gym']
});
const blackTie = garment('Black Tie', {
    category: 'Accessories', subcategory: 'Tie', primaryColor: 'Black', formality: 'Business',
    fit: 'Structured', warmth: 1, material: 'Silk', occasions: ['Office', 'Business meeting', 'Wedding']
});
const brownBelt = garment('Brown Leather Belt', {
    category: 'Accessories', subcategory: 'Belt', primaryColor: 'Brown', formality: 'Business',
    fit: 'Structured', warmth: 1, material: 'Leather', occasions: ['Office', 'Business meeting', 'Wedding']
});
const camelCoat = garment('Camel Coat', {
    category: 'Outerwear', subcategory: 'Coat', primaryColor: 'Camel', formality: 'Smart casual',
    fit: 'Structured', warmth: 3, material: 'Wool', occasions: ['Office', 'Dinner', 'Date']
});

function itemNames(shortlist: ReturnType<typeof generateShortlist>, index = 0): string[] {
    return shortlist[index]?.items.map(item => item.name) ?? [];
}

const representativeWardrobe = [
    whiteOxford, blackBlazer, navyTrousers, brownLoafers,
    blackTee, blueJeans, whiteSneakers, blackTrainingTee, runningShoes
];

test('Gym selects activewear and reports a missing sports bottom instead of using jeans', () => {
    const shortlist = generateShortlist(
        prompt({ occasion: 'Gym' }),
        [blackTrainingTee, runningShoes, blueJeans, blackTee, whiteSneakers],
        null
    );
    const names = itemNames(shortlist);

    assert.ok(names.includes('Black Training Tee'));
    assert.ok(names.includes('Running Shoes'));
    assert.ok(!names.includes('Blue Jeans'));
    assert.deepEqual(shortlist[0]?.missingPieces, ['neutral bottom']);
});

test('Every supported occasion produces an occasion-aware shortlist', () => {
    const occasions = ['Daily wear', 'University', 'Office', 'Business meeting', 'Dinner', 'Party', 'Wedding', 'Gym', 'Vacation', 'Date'];
    const formalOccasions = new Set(['Office', 'Business meeting', 'Dinner', 'Party', 'Wedding', 'Date']);

    for (const occasion of occasions) {
        const shortlist = generateShortlist(prompt({ occasion }), representativeWardrobe, null);
        const names = itemNames(shortlist);
        assert.ok(names.length > 0, `${occasion} should produce a candidate`);

        if (occasion === 'Gym') {
            assert.ok(names.includes('Black Training Tee'), 'Gym should use activewear');
            assert.ok(!names.includes('Blue Jeans'), 'Gym should not use jeans');
        } else if (formalOccasions.has(occasion)) {
            assert.ok(
                shortlist[0]?.items.some(item => ['Business', 'Cocktail', 'Formal'].includes(item.formality)),
                `${occasion} should contain a refined garment`
            );
        } else {
            assert.ok(names.includes('White Sneakers'), `${occasion} should remain practical`);
        }
    }
});

test('Every supported dress code changes or validates the formal direction', () => {
    const dressCodes = ['Casual', 'Smart Casual', 'Business Casual', 'Business Formal', 'Cocktail'];
    for (const dressCode of dressCodes) {
        const shortlist = generateShortlist(
            prompt({ occasion: 'Daily wear', dressCode }),
            representativeWardrobe,
            null
        );
        assert.ok(shortlist.length > 0, `${dressCode} should produce a candidate`);
        if (['Business Formal', 'Cocktail'].includes(dressCode)) {
            assert.ok(
                shortlist[0]?.items.some(item => ['Business', 'Cocktail', 'Formal'].includes(item.formality)),
                `${dressCode} should not fall back to a purely casual look`
            );
        }
    }
});

test('Business meeting prioritizes tailored garments over the casual daily look', () => {
    const wardrobe = [whiteOxford, blackBlazer, navyTrousers, brownLoafers, blackTee, blueJeans, whiteSneakers];
    const daily = itemNames(generateShortlist(prompt({ occasion: 'Daily wear' }), wardrobe, null));
    const business = itemNames(generateShortlist(prompt({ occasion: 'Business meeting' }), wardrobe, null));

    assert.ok(daily.includes('Blue Jeans'));
    assert.ok(!daily.includes('Navy Trousers'));
    assert.ok(business.includes('Navy Trousers'));
    assert.ok(business.includes('Brown Loafers'));
    assert.ok(!business.includes('Blue Jeans'));
});

test('An explicit formal dress code overrides a casual occasion', () => {
    const wardrobe = [whiteOxford, blackBlazer, navyTrousers, brownLoafers, blackTee, blueJeans, whiteSneakers];
    const result = itemNames(generateShortlist(
        prompt({ occasion: 'Daily wear', dressCode: 'Business Formal' }),
        wardrobe,
        null
    ));

    assert.ok(result.includes('White Oxford Shirt'));
    assert.ok(result.includes('Navy Trousers'));
    assert.ok(result.includes('Brown Loafers'));
    assert.ok(!result.includes('Blue Jeans'));
});

test('Required and excluded garments are respected', () => {
    const wardrobe = [whiteOxford, blackBlazer, navyTrousers, brownLoafers, blackTee, blueJeans, whiteSneakers];
    const result = itemNames(generateShortlist(
        prompt({
            occasion: 'Daily wear',
            specificRequirements: ['Black T-Shirt'],
            excludedGarments: ['White Sneakers']
        }),
        wardrobe,
        null
    ));

    assert.ok(result.includes('Black T-Shirt'));
    assert.ok(!result.includes('White Sneakers'));
});

test('Recent recommendations receive a rotation penalty when a valid alternative exists', () => {
    const secondTop = garment('Ivory Knit Polo', {
        category: 'Tops', subcategory: 'Shirt', primaryColor: 'Ivory', formality: 'Smart casual',
        fit: 'Relaxed', warmth: 1, material: 'Knit', occasions: ['Daily wear', 'University']
    });
    const secondBottom = garment('Beige Chinos', {
        category: 'Bottoms', subcategory: 'Trouser', primaryColor: 'Beige', formality: 'Smart casual',
        fit: 'Relaxed', warmth: 2, material: 'Cotton', occasions: ['Daily wear', 'University']
    });
    const wardrobe = [blackTee, blueJeans, whiteSneakers, secondTop, secondBottom];
    const first = itemNames(generateShortlist(prompt(), wardrobe, null));
    const rotated = itemNames(generateShortlist(prompt({ recentlyRecommendedGarments: first }), wardrobe, null));

    assert.ok(first.length > 0);
    assert.ok(rotated.length > 0);
    assert.ok(rotated.some(name => !first.includes(name)));
});

test('Cold weather adds an appropriate outer layer', () => {
    const shortlist = generateShortlist(
        prompt({ occasion: 'Business meeting', weather: 'Cold, 45°F' }),
        [whiteOxford, navyTrousers, brownLoafers, blackBlazer, camelCoat],
        null
    );
    const names = itemNames(shortlist);

    assert.ok(names.includes('White Oxford Shirt'));
    assert.ok(names.includes('Brown Loafers'));
    assert.ok(names.includes('Black Blazer') || names.includes('Camel Coat'));
});

test('Hot weather does not force an unnecessary outer layer', () => {
    const shortlist = generateShortlist(
        prompt({ occasion: 'Business meeting', weather: 'Hot, 95°F' }),
        [whiteOxford, navyTrousers, brownLoafers, blackBlazer, camelCoat],
        null
    );
    const names = itemNames(shortlist);

    assert.ok(names.includes('White Oxford Shirt'));
    assert.ok(names.includes('Navy Trousers'));
    assert.ok(names.includes('Brown Loafers'));
    assert.ok(!names.includes('Camel Coat'));
});

test('A recently worn outfit is deprioritized when an equivalent alternative exists', () => {
    const recentlyWornTop = { ...blackTee, lastWorn: new Date().toISOString() };
    const recentlyWornBottom = { ...blueJeans, lastWorn: new Date().toISOString() };
    const alternativeTop = garment('Ivory Knit Polo', {
        category: 'Tops', subcategory: 'Shirt', primaryColor: 'Ivory', formality: 'Smart casual',
        fit: 'Relaxed', warmth: 1, material: 'Knit', occasions: ['Daily wear', 'University']
    });
    const alternativeBottom = garment('Beige Chinos', {
        category: 'Bottoms', subcategory: 'Trouser', primaryColor: 'Beige', formality: 'Smart casual',
        fit: 'Relaxed', warmth: 2, material: 'Cotton', occasions: ['Daily wear', 'University']
    });
    const result = itemNames(generateShortlist(
        prompt(),
        [recentlyWornTop, recentlyWornBottom, whiteSneakers, alternativeTop, alternativeBottom],
        null
    ));

    assert.ok(result.includes('Ivory Knit Polo'));
    assert.ok(result.includes('Beige Chinos'));
});

test('An incomplete wardrobe returns a coherent partial look and missing shoe color', () => {
    const shortlist = generateShortlist(
        prompt({ occasion: 'Daily wear' }),
        [blackTee, blueJeans],
        null
    );
    const names = itemNames(shortlist);

    assert.deepEqual(names, ['Black T-Shirt', 'Blue Jeans']);
    assert.deepEqual(shortlist[0]?.missingPieces, ['neutral shoes']);
});

test('Formal occasions can add a purposeful accessory while casual looks do not', () => {
    const formalWardrobe = [whiteOxford, blackBlazer, navyTrousers, brownLoafers, blackTie, brownBelt];
    const formalNames = itemNames(generateShortlist(prompt({ occasion: 'Business meeting', includeAccessories: true }), formalWardrobe, null));
    const casualNames = itemNames(generateShortlist(prompt({ occasion: 'Daily wear' }), formalWardrobe, null));

    assert.ok(formalNames.includes('Black Tie') || formalNames.includes('Brown Leather Belt'));
    assert.ok(!casualNames.includes('Black Tie'));
    assert.ok(!casualNames.includes('Brown Leather Belt'));
});

test('Accessories are included only when explicitly enabled', () => {
    const wardrobe = [whiteOxford, navyTrousers, brownLoafers, blackTie, brownBelt];
    const withoutAccessories = itemNames(generateShortlist(prompt({ occasion: 'Business meeting', includeAccessories: false }), wardrobe, null));
    const withAccessories = itemNames(generateShortlist(prompt({ occasion: 'Business meeting', includeAccessories: true }), wardrobe, null));

    assert.ok(!withoutAccessories.includes('Black Tie'));
    assert.ok(!withoutAccessories.includes('Brown Leather Belt'));
    assert.ok(withAccessories.includes('Black Tie') || withAccessories.includes('Brown Leather Belt'));
});

test('The recommendation contract keeps at most two requested occasions', () => {
    const shortlist = generateShortlist(
        prompt({ occasion: 'Office, Dinner, Gym' }),
        representativeWardrobe,
        null
    );

    assert.ok(shortlist.length > 0);
    assert.ok(shortlist[0]?.items.some(item => item.occasions.includes('Office') || item.occasions.includes('Dinner')));
    assert.ok(!shortlist[0]?.items.some(item => item.name === 'Black Training Tee'));
});

test('Surprise me rotates away from the previous combination', () => {
    const wardrobe = [blackTee, blueJeans, whiteSneakers, whiteOxford, navyTrousers, brownLoafers];
    const first = generateShortlist(prompt({ occasion: 'Surprise me', recentlyRecommendedGarments: [] }), wardrobe, null);
    const firstNames = itemNames(first);
    const second = generateShortlist(prompt({ occasion: 'Surprise me', recentlyRecommendedGarments: firstNames }), wardrobe, null);
    const secondNames = itemNames(second);

    assert.ok(firstNames.length > 0);
    assert.ok(secondNames.length > 0);
    assert.notDeepEqual(secondNames, firstNames);
});

test('A recommendation can be generated without selecting an occasion', () => {
    const shortlist = generateShortlist(
        prompt({ occasion: '', formalityLevel: null }),
        [blackTee, blueJeans, whiteSneakers],
        null
    );

    assert.ok(shortlist.length > 0);
    assert.deepEqual(itemNames(shortlist), ['Black T-Shirt', 'Blue Jeans', 'White Sneakers']);
});

test('The formality scale changes the result without requiring a dress-code label', () => {
    const wardrobe = [blackTee, blueJeans, whiteSneakers, whiteOxford, navyTrousers, brownLoafers];
    const relaxed = itemNames(generateShortlist(prompt({ formalityLevel: 0 }), wardrobe, null));
    const formal = itemNames(generateShortlist(prompt({ formalityLevel: 4 }), wardrobe, null));

    assert.ok(relaxed.includes('Black T-Shirt'));
    assert.ok(relaxed.includes('Blue Jeans'));
    assert.ok(formal.includes('White Oxford Shirt'));
    assert.ok(formal.includes('Navy Trousers'));
    assert.ok(formal.includes('Brown Loafers'));
});

test('Free-text context informs the stylist when the occasion is broad', () => {
    const wardrobe = [blackTee, blueJeans, whiteSneakers, whiteOxford, navyTrousers, brownLoafers];
    const result = itemNames(generateShortlist(
        prompt({ occasion: 'Other', contextNote: 'Presentation for an important client' }),
        wardrobe,
        null
    ));

    assert.ok(result.includes('White Oxford Shirt'));
    assert.ok(result.includes('Navy Trousers'));
    assert.ok(result.includes('Brown Loafers'));
});
