# KIDNOVA

Nursery school management system (static site + Supabase).

## Setup
1. Supabase SQL Editor: run `supabase.sql`.
2. Supabase Auth > Email: turn off "Confirm email".
3. Set your Supabase URL and publishable key in `config.js`.
4. Deploy the folder to Vercel (no build step).

The first account that signs up becomes the Super Admin; the Super Admin adds all other users.

## Android app (kidnova.apk)

`android/` holds a small native Android app (no Gradle) that opens kidnova.site full-screen,
sends phone/SMS/WhatsApp links to the phone's apps, and saves report PDFs to Downloads.
The built file is served at https://kidnova.site/kidnova.apk and teachers see an install card on Home.

Build: `ANDROID_HOME=… KEYSTORE=… KEYSTORE_PASS=… android/build.sh` (needs build-tools 35 and platform 34).
Always sign updates with the same keystore (kept outside this repository), raise `versionCode`/`versionName`
in `android/AndroidManifest.xml`, `BuildInfo.VERSION`, and `APP.version` in `index.html`.
