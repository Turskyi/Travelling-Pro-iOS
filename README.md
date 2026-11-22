# Travelling

A native iOS app for tracking visited countries, trips, cities, photos, and travel progress.

## Features

- Country catalog with English and Ukrainian names
- Country and code search, visited-only filtering, and travel progress
- Visit dates, city visits, optional GPS-assisted city lookup, and country photos
- Offline-first local storage with JSON backup and restore
- Traveller profiles, friend codes, visibility controls, and shared travel lists
- Firebase Authentication and cloud backup/restore
- Google Sign-In
- WidgetKit home-screen widget
- StoreKit 2 auto-renewable subscription for automatic cloud sync, with the
  backend's `FREE_ACCESS_FOR_ALL` switch able to grant that access to everyone

Country tracking, city visits, photos, and local backups remain available without a
subscription or account.

## Technology

- Swift and SwiftUI
- iOS 17+
- Firebase Auth, Firestore, and Storage
- Google Sign-In for iOS
- StoreKit 2
- WidgetKit
- PhotosUI
- Core Location
- App Groups

## Project setup

Open `Travelling.xcodeproj` in Xcode and select the `Travelling` scheme.

### Firebase

Place a project-specific `GoogleService-Info.plist` in `Travelling/`.
The file is intentionally local configuration and must not be committed.

In Firebase:

1. Enable Google under Authentication > Sign-in method.
2. Configure Firestore and Storage security rules for the `travellers/{uid}`,
   `users/{uid}/backup.json`, and `users/{uid}/photos` paths used by the app.
3. Configure a production OAuth client for the iOS bundle ID.

### Google Sign-In

The app uses the `CLIENT_ID` and `REVERSED_CLIENT_ID` from
`GoogleService-Info.plist`. The URL scheme must remain configured in
`Travelling-Info.plist`.

### App Group

The app and widget use:

```text
group.io.github.turskyi.Travelling
```

Enable this App Group for both `io.github.turskyi.Travelling` and
`io.github.turskyi.Travelling.TravelWidget` in the Apple Developer account and
under Xcode Signing & Capabilities.

### Subscription

The StoreKit product ID is:

```text
cloud_backup
```

Create it as an auto-renewable subscription in App Store Connect, complete the
subscription business and review information, and test it with a Sandbox account.
Basic travel tracking is not gated behind this subscription. When the web backend's
`FREE_ACCESS_FOR_ALL` is `true`, the app reads that status from the authenticated
`/api/subscription/status` endpoint and enables automatic sync without a purchase.

## App Store requirements

Before submitting:

- Add Sign in with Apple if required by the App Review account-authentication
  guidelines.
- Complete App Privacy disclosures for location, photos, account data, purchases,
  and Firebase services.
- Add and verify the privacy policy, support, and account-deletion URLs.
- Test Google Sign-In, account deletion, cloud backup/restore, traveller sharing,
  subscription purchase/restore, and widget updates on a physical iPhone.
- Confirm App Group and Firebase production configuration for the signed release
  build.

## Building

```sh
xcodebuild \
  -project Travelling.xcodeproj \
  -scheme Travelling \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  build
```
