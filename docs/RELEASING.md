# Releasing Ferrite

`scripts/release.sh` does the mechanical work: tests, universal build
(arm64 + x86_64), hardened-runtime Developer ID signing, notarization,
stapling, the zip artifact, and the cask/version bumps. This file is the
operator context around it.

## One-time setup

1. **Apple Developer enrollment** (paid). Notarization and Developer ID
   certificates require it; there is no free path. The App Store is not an
   option for Ferrite — the Accessibility API is incompatible with sandboxing.
2. **Developer ID Application certificate.** In [developer.apple.com →
   Certificates](https://developer.apple.com/account/resources/certificates/list),
   create a *Developer ID Application* certificate (Keychain Access →
   Certificate Assistant → Request a Certificate From a Certificate Authority
   for the CSR), download it, double-click into the login keychain. Verify:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. **Notarization credentials.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) (Sign-In and Security →
   App-Specific Passwords), then:

   ```sh
   xcrun notarytool store-credentials ferrite-notary \
     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>
   ```

   (`FERRITE_NOTARY_PROFILE` overrides the profile name;
   `FERRITE_RELEASE_IDENTITY` overrides identity auto-detection.)

## Per release

```sh
scripts/release.sh 1.0.0
```

The script refuses a dirty tree, runs `swift test`, builds, signs, notarizes,
staples, writes `dist/Ferrite-1.0.0.zip`, and rewrites `Casks/ferrite.rb`
(version + sha256) plus the dev-build default version in `make-app.sh`.
Then follow its printed tail: commit the bumps, tag `v1.0.0`, push, and
`gh release create v1.0.0 dist/Ferrite-1.0.0.zip`.

Release tags are plain `vX.Y.Z` — the cask URL interpolates them. (Milestone
tags like `v0.11.0-ferrite` predate this and are not release tags.)

The cask lives in this repository; pushing `main` *is* publishing the cask:

```sh
brew tap vhark/ferrite https://github.com/vhark/Ferrite.git
brew install --cask ferrite
```

## Dry run (no Apple account needed)

```sh
scripts/release.sh 1.0.0 --no-notarize
```

Builds the identical artifact shape — universal, hardened runtime, zipped —
signed with the "Ferrite Dev" fallback when no Developer ID identity exists.
Skips notarization and leaves the cask and version defaults untouched.

## Failure notes

- **Notarization "Invalid":** `xcrun notarytool log <submission-id>
  --keychain-profile ferrite-notary` lists the per-file complaints. The usual
  suspects are a missing `--options runtime` or an unsigned nested binary;
  `make-app.sh` signs the whole bundle with hardened runtime under
  `FERRITE_HARDENED=1`, and the only nested content is the KeyboardShortcuts
  localization bundle (no code, needs no signature).
- **Never ad-hoc sign anything user-facing** (platform finding 6): the
  Accessibility grant is keyed to the signature. Developer ID is stable
  across builds, so released updates keep the user's grant — same property
  the self-signed dev identity provides locally.
- **`spctl -a -t exec` rejects the app** after a successful notarize: the
  ticket didn't staple — re-run `xcrun stapler staple build/Ferrite.app` and
  re-zip; offline Macs need the staple, Gatekeeper can't fetch tickets for them.
