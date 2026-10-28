# Apparelgio

Apparelgio is a native iOS and iPadOS application that combines a digital wardrobe with artificial intelligence to help users organize garments and generate personalized outfit recommendations.

## Main Features

- Email and password authentication through Appwrite.
- Digital wardrobe with garment categories, attributes, filters, and favorites.
- Garment recognition from photographs using Gemini through a protected backend.
- Outfit recommendations based on occasion, formality, weather, and personal preferences.
- Weather data from Open-Meteo.
- Local persistence with SwiftData and cloud synchronization through Appwrite.
- Adaptive interfaces for iPhone and iPad.

## Technology Stack

- **Mobile:** Swift, SwiftUI, SwiftData, and Xcode.
- **Backend:** Node.js, TypeScript, Express, and Docker.
- **Cloud services:** Appwrite for authentication, database, and storage.
- **Artificial intelligence:** Gemini for garment analysis and outfit recommendations.
- **Weather:** Open-Meteo.
- **Deployment:** Render.

## Project Structure

- `Apparelgio/`: native iOS and iPadOS source code.
- `backend/`: TypeScript backend and recommendation engine.
- `Apparelgio.xcodeproj/`: Xcode project configuration.
- `render.yaml`: Render deployment configuration.

## Running the Mobile App

Open `Apparelgio.xcodeproj` in Xcode, select an iPhone or iPad simulator, and run the `Apparelgio` scheme. The project targets iOS/iPadOS 17.6 or later.

## Running the Backend

```bash
cd backend
npm ci
npm run build
npm start
```

The backend reads its configuration from environment variables. Use `.env.example` as a reference and keep real credentials outside version control.

## Academic Project

Apparelgio is an academic software project focused on the application of native mobile development, artificial intelligence, cloud services, and contextual recommendation systems to personal wardrobe management.

## License

This project is distributed under the MIT License. See `LICENSE` for details.
