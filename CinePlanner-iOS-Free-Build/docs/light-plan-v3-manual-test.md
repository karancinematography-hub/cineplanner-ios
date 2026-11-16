# CinePlanner Light Plan manual test checklist

Start with an Android tablet, then repeat the compact-layout checks on a phone. Record the device model, Android version, build version, and which checks passed. Use a test project and two distinguishable JPEG or PNG images.

## Install and landscape launch

- [ ] On a fresh tablet install, hold the device vertically and launch CinePlanner with auto-rotate off. The workspace browser opens horizontally. Close the app, turn the tablet around, and relaunch with auto-rotate on. Check both landscape directions. Repeat on a phone when available.
- [ ] On a 4:3 or 16:10 tablet in landscape, check the full-width browser, compact search/sort/filter toolbar, and clearly aligned record rows. Tap a populated shoot day and confirm Light Plan opens directly on the first available take in numeric order, skipping branches with no takes. Press Back to return to the shoot-day list. Use the shoot day menu’s Browse scenes action to reach the workspace hierarchy. Tap an empty day and confirm Light Plan opens with Add available.
- [ ] Upgrade an existing debug install signed by the same key. Keep its app data. Open an older take with a populated parent shot and check that its canvas and grabs appear in Light Plan. Edit the take, reopen it, and check that the original shot and its legacy tools still show the original content.

## Tablet UI and accessibility

- [ ] Compare the browser, Light Plan, Add and number dialogs, Camera settings, Production details, legacy shot tools, and Restore backup. Check for a warm ivory app background, white cards, ink text and icons, charcoal primary actions, muted olive selection accents, warm stone controls, and fine borders.
- [ ] On a landscape tablet, confirm the canvas fills about 70% of the work area, both preview images fit without cropping, and the single Add button sits immediately right of Redo. Check that both toolbars omit the old titles, use medium glyphs, and keep comfortable touch targets. Repeat on a landscape phone and confirm that Go to, Add, and the grab controls are reachable.
- [ ] If the tablet supports split screen, narrow the window with a take open. Confirm the canvas and grabs stack. Return to full width and confirm the same take and canvas position remain. Repeat with larger system text.
- [ ] In the number dialog, check that the fields sit side by side on the tablet. Enter a partial number, then narrow the window or open the keyboard. The draft survives, the fields can scroll, and Save and Cancel remain reachable.
- [ ] With TalkBack or a keyboard, move through the browser toolbar and Light Plan controls. Check that focus is visible, icon actions are announced, and the order follows the screen from header to canvas, grabs, and take navigation.

## Screen and creation

- [ ] Create an organization, project, and shoot day in the browser. Open Light Plan from the shoot day. The canvas is the largest area, the two grabs are stacked to its right, and there is one Add button in the header.
- [ ] Check that Scene, Shot, and Take display digits or a blank number. Tap each current header number to open its number field. Swipe each number strip and verify it opens the centered record only after scrolling settles. Check the accessible names for Print Data, Reset Take, Undo, Redo, Go to, and Add.
- [ ] Open Add. Confirm all three choices are displayed and Create is disabled until an eligible choice is selected. Switch choices where available and confirm only one remains checked. Cancel and verify that no record was created.
- [ ] Create a New Scene from the empty shoot day. Pick No at the copy prompt. All three fields start blank. Try saving with a missing field. Try entering letters, then fill all three fields with digits. Check the saved numbers, empty canvas, and blank grab slots.
- [ ] Add a light, camera marker, subject, and freehand stroke. Move and rotate a fixture. Upload different images to both grabs. From this populated take, exercise **New Scene Yes**, **New Scene No**, **New Shot Yes**, and **New Shot No**, reopening the populated source before each check. Yes copies the full drawing. No leaves the canvas empty. The new record number fields and grab slots start blank. Editing a copy leaves the source unchanged.
- [ ] Create a New Shot and check that it uses the current scene number and asks for Shot and Take. Try reusing an existing shot number with a different number of leading zeros and confirm the duplicate is reported.
- [ ] From Take `02`, create a New Take. Expect `03`, the same Scene and Shot values, the copied canvas, and blank grabs and take metadata. Repeat from Take `02` and confirm the occupied `03` is reported. Try New Take from an unnumbered legacy take and check that it asks you to assign a number.
- [ ] If you have an older shot with no takes, open it and create its first take. Confirm `01`, the legacy canvas, and blank grabs.

## Go to, number scrollers, and the Take slider

- [ ] Prepare at least two scenes in one day and another scene on a different day. Open Go to and confirm the picker shows only Scene, Shot, and Take for the current day. Open an exact take, then try Open scene and Open shot. Check that a populated branch opens its lowest-numbered descendants and an empty branch stays at the selected level.
- [ ] For a legacy record named `Kitchen wide` or `03B`, confirm the header number starts blank and Go to still shows the name. Use Set number to enter `02`. Verify that the record keeps its name, canvas, and grabs. Use Edit number to change it, then cancel a second edit.
- [ ] Tap a numbered header value and enter its digits without leading zeros. Check that the correct record opens. Try an unused number and confirm the message appears while the current record stays open. If the workspace contains duplicate legacy numbers, confirm the jump offers both matches.
- [ ] With takes `01`, `03`, and `10` in a shot, drag the Take slider to another stop. Confirm the old canvas and grabs remain while dragging and switch together on release. Try both ends, verify the slider skips gaps and stays in the shot, then pan and draw on the canvas to check that those gestures leave the take selected.
- [ ] Switch takes after editing the canvas. Confirm the destination shows its own canvas and grabs and that Undo cannot change the take you just left.

## Grabs, history, and output

- [ ] With two populated grabs, check that the previews are uncropped and that their titles and action rows are hidden. Tap a preview to show its title and Upload, Camera, and Retake below it. Tap the other preview to close the first tray, then tap it again to collapse. Repeat with an empty slot.
- [ ] Reveal the controls and try Upload and Camera in both slots. Confirm returning from the picker or camera brings the app back to landscape and updates only the intended take and slot. Cancel each system flow once and check that the previous image remains.
- [ ] Use Retake on a populated slot. Cancel the confirmation once. Then confirm and capture a different image. Undo and redo the replacement and check the two previews.
- [ ] To exercise camera recovery, enable Android's **Don't keep activities** developer setting, capture a photo, and return to CinePlanner. If a pending capture is shown, recover it into its named take and slot. Repeat with Dismiss and confirm the prior grab remains. Turn the developer setting off after the test.
- [ ] On a populated take, cancel Reset Take and check the drawing. Confirm Reset Take and verify the canvas clears while labels and saved grabs remain. Undo and redo. Undo a new record creation and check that the previous selection returns. Redo and verify the same record reappears.
- [ ] Tap Print Data and save or open the PDF from Android's share sheet. Check the active take's Scene, Shot, and Take values, drawing, available grabs, and any saved eligible notes. Return to the app and check landscape.
- [ ] In airplane mode, force-stop and reopen the app. Open the edited take through the browser and verify its saved labels, canvas, and grabs. Undo and redo operate within the current editing sequence.

For any failure, record the selected record, exact taps, expected result, actual result, and a screenshot if available.
