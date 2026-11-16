# CinePlanner iOS free build

Start with docs/ios-free-build.md for the complete Windows and GitHub steps.

Upload this folder's contents into a new public GitHub repository. The manual workflow is .github/workflows/ios-unsigned.yml. It builds CinePlanner-unsigned.ipa using a standard macOS runner, without signing secrets. Native compilation and iPad testing are pending until that workflow is run.

The iPad is only needed later for free personal signing and installation through AltStore Classic.
