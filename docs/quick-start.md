# Quick Start

Set up Mac Phone Bridge on your Mac and your Android phone. It takes about ten minutes, and you don't need to be technical.

This is a **beta**: everything is built, but it's still being tested on different phones. If something doesn't work, the [Feature checklist](#feature-checklist) at the end says how to tell us.

## Before you start

You need:

- A Mac with **macOS 14 Sonoma or later**.
- An Android phone with **Android 10 or later**. Full mode (seeing and using the phone's screen on the Mac) needs **Android 11 or later**.
- Both on the **same Wi-Fi**. Turn off any VPN on either device while you set it up.

## 1. Install the app on your Mac

1. Download **MacPhoneBridge-0.9.0-beta.1.dmg** from the [beta release page](https://github.com/venkataPhanindraVutla/mac-phone-bridge/releases/tag/v0.9.0-beta.1).
2. Open the downloaded file. A window opens with the app and your Applications folder.
3. Drag **Mac Phone Bridge** onto **Applications**.
4. Open your Applications folder and double-click **Mac Phone Bridge**.

### If your Mac says it can't open the app

The beta isn't signed by Apple yet, so macOS asks you to confirm that you trust it. You only do this once.

**macOS 15 Sequoia and later:**

1. In the message that says Apple could not verify the app, click **Done**.
2. Open **System Settings** and choose **Privacy & Security**.
3. Scroll down to **Security**. Next to the line saying Mac Phone Bridge was blocked, click **Open Anyway**.
4. Enter your Mac password (or use Touch ID), then click **Open Anyway** once more.

**macOS 14 Sonoma:**

1. In Applications, hold **Control** and click **Mac Phone Bridge**, then choose **Open**.
2. Click **Open** in the message that appears.

When it's running, a small **phone icon** appears in the **menu bar** at the top right of your screen, with a line through it until your phone connects. That's where you use the app.

If your Mac asks to allow Mac Phone Bridge to find devices on your local network, click **Allow**. It needs this to find your phone.

## 2. Install the app on your phone

1. On your phone, open the [beta release page](https://github.com/venkataPhanindraVutla/mac-phone-bridge/releases/tag/v0.9.0-beta.1) and tap **MacPhoneBridge-0.9.0-beta.1.apk** to download it. (On the Get started page of the website, you can scan a QR code with your phone's camera instead.)
2. When the download finishes, tap **Open**.
3. If the phone says it isn't allowed to install apps from this source, tap **Settings**, turn on **Allow from this source**, then go back and tap **Install**.
4. If **Google Play Protect** shows a warning, tap **More details** and then **Install anyway**. It warns because the app isn't from the Play Store yet.
5. Some phones (vivo, Xiaomi, OPPO and others) show one more warning. Choose the option to install anyway.

## 3. Pair your phone and your Mac

1. On your Mac, click the menu bar icon and choose **Pair a phone…**. A QR code appears.
2. On your phone, open **Mac Phone Bridge** and tap **Pair with your Mac**, then **Scan the code**. Allow the camera when asked.
3. Point the phone at the QR code on your Mac.
4. Both screens now show a 6-digit code. If they match, tap **Confirm** on the phone.
5. The phone says **Paired with** your Mac's name. Tap **Done**.

You only pair once. From now on, the two connect by themselves whenever they're on the same Wi-Fi.

## 4. Turn on what you want to use

The phone app's home screen has a switch for each feature. Turn on the ones you want. The phone asks for each permission the first time you turn a feature on:

- **Show notifications on your Mac:** tap **Allow notification access**, find Mac Phone Bridge in the list and turn it on.
- **Calls on your Mac** and **Share contacts with your Mac:** allow phone and contacts access. Call audio stays on your phone.
- **Send screenshots to your Mac** and **Show recent photos on your Mac:** allow access to all photos.
- **Share clipboard with your Mac**, **Control media from your Mac**, **Sync Do Not Disturb with your Mac** and **Browse phone files from your Mac** work the same way.

On the Mac, allow notifications when it asks, so phone notifications can show up. To use the phone as a trackpad or presentation remote, allow Mac Phone Bridge in **System Settings › Privacy & Security › Accessibility**.

## 5. Keep it connected when the phone is locked

To save battery, Android can stop apps while the screen is off. To stop that from cutting your Mac off:

1. When the phone app shows **Stay connected when the phone is locked**, tap **Allow in the background**.
2. If it then says **On this phone, also turn this on**, tap **Open app settings** and turn on the setting it names. For example:
   - **Samsung:** Settings › Battery › Background usage limits › Never sleeping apps › add Mac Phone Bridge.
   - **Xiaomi, Redmi, POCO:** Settings › Apps › Manage apps › Mac Phone Bridge › Autostart on, and Battery saver › No restrictions.
   - **vivo, iQOO:** Settings › Battery › Background power consumption management › Mac Phone Bridge › Allow.
   - **OPPO, OnePlus, realme:** Settings › Apps › App management › Mac Phone Bridge › Battery usage › Allow background activity.

## 6. Full mode: the whole phone in a Mac window (optional)

Full mode shows your phone's screen in a window on your Mac, with its sound, and lets you use it with your Mac's mouse and keyboard. It needs Android 11 or later and a one-time setup with a developer setting called Wireless debugging. The phone app walks you through it:

1. On the phone app's home screen, under **Allow your Mac to show this screen**, tap **Set up Full mode**.
2. Turn on Developer options: open **Settings › About phone** and tap **Build number** seven times. (On some phones, Build number is under Software information.)
3. Go back to Settings, open **Developer options**, and turn on **Wireless debugging**. Allow it on this network.
4. Tap **Pair device with pairing code** and keep that screen open.
5. Pull down the notification from Mac Phone Bridge and type the code from the Wireless debugging screen into it.
6. When the phone app says **Full mode is ready.**, click the menu bar icon on your Mac and choose **Show Phone Screen**.

On Xiaomi, Redmi and POCO phones, also turn on **USB debugging (Security settings)** in Developer options. On vivo, iQOO, OPPO and OnePlus phones, turn on **Disable permission monitoring**. Without it, taps and typing from the Mac won't work. The phone app tells you if your phone needs this.

After the phone restarts or joins a different Wi-Fi network, tap **Re-enable Full mode** in the phone app. To turn Full mode off completely, turn off Wireless debugging.

## If something isn't working

- **The phone can't find the Mac:** check that both are on the same Wi-Fi and that no VPN is on. Guest networks and some office networks block devices from seeing each other, so try a home network or your phone's hotspot.
- **Your Mac asks to allow access to a Keychain item:** click **Always Allow**. This beta asks again after each update. If a message mentions *exporting* a key, click **Deny** and tell us.
- **Notifications stop when the phone is locked:** go through step 5 again for your phone's brand.
- **"Your Mac doesn't recognise this phone any more":** pair again (step 3).
- **Full mode stopped working:** tap **Re-enable Full mode** on the phone.

## Updating and removing

- **Update:** download the new DMG and APK from the releases page and install them the same way. Your pairing is kept.
- **Remove from the Mac:** in the menu bar icon, choose **Forget** your phone, quit the app, then drag Mac Phone Bridge from Applications to the Trash.
- **Remove from the phone:** uninstall it like any other app.

This beta is signed with a temporary key. When version 1.0 comes out, you'll need to uninstall the beta from your phone before installing 1.0, and pair again.

## Feature checklist

Please try these and tell us what worked and what didn't. Include your phone's make and model and its Android version (Settings › About phone), and your Mac's model and macOS version (Apple menu › About This Mac).

- [ ] The Mac app opens and shows its menu bar icon.
- [ ] The phone app installs and pairs with the Mac.
- [ ] A phone notification shows up on the Mac, and replying from the Mac works.
- [ ] A one-time code in a notification shows **Copy code** on the Mac.
- [ ] An incoming call shows on the Mac, and answering, declining and hanging up work.
- [ ] Text copied on the Mac can be pasted on the phone, and the other way round.
- [ ] A file dragged onto the Phone window arrives on the phone, and **Send to Mac** from the phone's share sheet arrives on the Mac.
- [ ] A screenshot taken on the phone appears on the Mac.
- [ ] Music playing on the phone can be paused and skipped from the Mac.
- [ ] **Find my phone** rings the phone, even on silent.
- [ ] Battery and signal show in the Mac's menu bar.
- [ ] It stays connected for an hour with the phone locked.
- [ ] Full mode shows the phone's screen, and clicking and typing from the Mac work.

Send results and problems on [GitHub issues](https://github.com/venkataPhanindraVutla/mac-phone-bridge/issues), or to whoever shared this beta with you.
