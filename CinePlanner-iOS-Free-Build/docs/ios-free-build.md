# Free Windows-to-iPad route

The included workflow builds an unsigned IPA on GitHub's standard macOS runner. It does not require your iPad, an Apple account, or signing secrets. This native build has not yet been run. The source was prepared on Windows; a successful workflow run is needed before an IPA exists.

## Build now

1. Extract CinePlanner-iOS-Free-Build.zip into a new folder.
2. Sign in to GitHub and create an empty PUBLIC repository named cineplanner-ios. This makes the uploaded app source publicly visible. Standard hosted Actions runners are free for public repositories. Do not choose paid or larger runners.
3. On the empty repository page choose uploading an existing file. Upload the extracted folder's CONTENTS, including .github, apps, docs, scripts, and README.md. Do not upload the ZIP or its enclosing folder. Commit the upload to main. The workflow must appear at .github/workflows/ios-unsigned.yml.
4. Open Actions, select Build iOS IPA, then Run workflow on main. If needed, enable Actions for the repository first.
5. Open the successful run and download CinePlanner-unsigned-IPA from Artifacts. Extract the downloaded archive to obtain CinePlanner-unsigned.ipa. Download within one day; artifacts expire after that to keep storage small.
6. Save the IPA locally until you have your iPad. If the run fails, save the failed step's log for diagnosis. An unsigned IPA cannot install by tapping it in Files.

## Install later

Use AltStore Classic, with AltServer on your Windows PC. Follow its official Windows guide linked below to install the required Apple software, connect and trust the iPad, enable Wi-Fi sync, and install AltStore using your free Apple account. Enable Developer Mode and trust the developer in iPad settings when prompted.

With AltServer running, transfer the IPA to iPad Files, open AltStore's My Apps tab, tap +, and select it. AltStore signs it for your device. Keep the same Apple account and app identity for future updates and export workspace backups before reinstalling. Refresh the app with AltServer available before seven days expire. No Apple Developer subscription is needed for this personal sideloading route.

## References

- https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job
- https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow
- https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
- https://faq.altstore.io/altstore-classic/your-altstore
