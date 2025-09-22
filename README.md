<div align="center">

<picture>
  <source srcset="Documentation/icon-dark.png" media="(prefers-color-scheme: dark)">
  <source srcset="Documentation/icon-light.png" media="(prefers-color-scheme: light)">
  <img src="Documentation/icon-light.png" alt="App Icon" width="100">
</picture>
<br/><br/>

A small yet powerful **macOS app** for taking & editing screenshots!

Inspired by Greenshot on Windows - the goal is to make a tiny app that can do the basics and look great while doing it. 

</div>

<p align="center">
    <a href="Documentation/App1.png"><img src="Documentation/App1.png" width="35%"></a>
    <a href="Documentation/App3.png"><img src="Documentation/App3.png" width="35%"></a>
    <a href="Documentation/App2.png"><img src="Documentation/App2.png" width="35%"></a>
</p>

## 🖥️ Features, Tools, and Settings

### Features

- Take screenshots!
  - With a global hotkey even when the app is in the background. 
- Multi monitor support. 
- Retina display ready. 
- Open Images for editing. 
  - Native "Open With" integration in Finder. 
- Copy to Clipboard / Save / Save As. 
- Undo / redo!
- Pinch to zoom / Double tap to zoom / cmd + scroll wheel to zoom. 
- Snip Gallery to view snips by date. 
- Liquid Glass first design. 
- Privacy focused - no network access or data collection - your snips are purely yours. 



### Tools

| Tool       | Shortcut   | Notes              |
|:---------------|:--------:|-------------------:|
| Take Screenshot              | ⌘ , ⇧ , 2     | Command + Shift + 2       |
| Pointer Tool                 | ⌘ , 1         | Moves objects around      |
| Pen Tool                     | ⌘ , 2         | Draw lines. |
| Arrow Tool                   | ⌘ , 3         | Draw lines with arrows.|
| Highlighter                  | ⌘ , 4         | Highlights. |
| Rectangle Tool               | ⌘ , 5         | Draw squres / rectangles |
| Oval Tool                    | ⌘ , 6         | Draw circles / ovals |
| Badge Tool                   | ⌘ , 7         | Incremental Numbers |
| Text Tool                    | ⌘ , 8         | Insert text. Colored backgrounds optional.  |
| Crop Tool                    | ⌘ , 9         | Crops. |
| Reset Zoom                   | ⌘ , 0         |  |
| Zoom In                      | ⌘ , +         |  |
| Zoom Out                     | ⌘ , -         |  |


### Settings

These settings are customizable by you. 
- File Save Destination
- Save Format
  - PNG
  - JPG (With Quality Slider)
  - HEIC (With Quality Slider)
- Downsample Retina Screenshots 
  - If you take a screenshot on a Retina or High-DPI display, it will downsample it to 1x immediately. 
- Automatically Save on Copy
  - When you take a screenshot, it can automatically save to disk. 
- Downsample Retina Screenshots for Copy
  - If a High-DPI screenshot exists, we can automatically downsample it to 1x for easier & quicker sharing. 
- Fit Images to Window
  - You can view your snips in "actual" size, or enhance them to take the full window size. 
- Hide Dock Icon
  - Since the app runs in the background, you may not want a visible dock icon constantly. 
- Start on Logon
  - Start the app when logging into your Mac. 


## 🖥️ Install & Minimum Requirements

- macOS 26.0 or later  
- Apple Silicon & Intel (Not tested on Intel)
- ~20 MB free disk space  


### ⚙️ Installation

Mac App Store

OR 

Download from Releases. It's signed & notarized!

### ⚙️ Build it yourself!

Clone the repo and build with Xcode:

```bash
git clone https://github.com/gbabichev/Screen-Snip.git
cd Screen-Snip
open "Screen Snip.xcodeproj"
```

## 📝 Changelog

### 1.1.0
- Added rotation for Rectangle Tool, Text Tool, Pasted object tool. 
- New Icon 
- Snip Gallery now shows the date of snips in the Window Titlebar. 

### 1.0.4
- Added keyboard navigation to move between thumbnails in the bottom row.

### 1.0.3
- Resolved issue with screen cursor not always displaying properly. 
- Optimized window close/reopen behavior during certain captures. 

### 1.0.2 
- Resolved regression with "Open With Screen Snip" not working in Finder. 

### 1.0.1
- Improved permissions UI when launching app. 

### 1.0 
- Initial Release. 

## 📄 License

MIT — free for personal and commercial use. 

## Privacy
<a href="Documentation/PrivacyPolicy.html">Privacy Policy</a>

## Support 
<a href="Documentation/Support.html">Support</a>

## Progress
<details>
<summary>Work in Progress</summary>

</details>

<details>
<summary>Completed</summary> 

- <del>Undo & Redo
- <del>Add Text fields with font colors, sizes, and background fill.
   - Click onto text area to adjust it. Not spwan new text boxes.
- <del>Add lines with arrows. 
- <del>Objects should be eraseable with delete key.
- <del>Add auto increment numbers. 
- <del>Add Crop.
- <del>Lines, Arrows, Shapes, numbers, etc should all be moveable objects. 
- <del>Add a highlighter
- <del>Open existing file
- <del>Paste on top & move stuff around. 
- <del>Add User Settings 
  - <del>User defined save folder. 
  - <del>User defined output type (PNG / JPG / HEIC) & quality slider. 
- <del>Refresh snaps button. 
- <del>Limit snap previews to ~10.
- <del>Add a Snap Browser
- <del>Multi-Monitor snaps. 
- <del>Global system hotkey for screenshots.</del> 
- <del>Handle 1x, 2x (Retina) snaps.
  - User setting to downsample retina in clipboard
- <del>User adjustable setting for Snap "fills" or "fits". 
- <del>Adjust liquid glass in app icon.
- <del>Add cmd+scroll with mouse.
- <del>Add pinch to zoom on trackpad.
- <del>User friendly menus. 
- <del>Hotkeys for tools.
- <del>Working Menu Bar commands with icons.
- <del>Add circle shape. 
- <del>Adjust tools so i can also move objects around in the same tool. 
- <del>Remove the double ContentView for the two modes.
- <del>line, oval, rect need to have separate colors not share the same color. 
- <del>Fix line colors changing.
- <del>Pen colors, shape colors, etc should be saved across app launches.
- <del>Update Pen & Oval tool menu bars being weird. 
- <del>Fix RAM usage.
- <del>Refresh thumbnail on click / copy to clipboard. 
- <del>Update Snap Gallery so I can see dates.
- <del>Add File and Edit Menu Bar entries. 
- <del>Fix arrow design.
- <del>Add double tap to zoom on mouse & trackpad.
- <del>Add cmd0, cmd+, cmd- for zoom controls. 
- <del>Remove debug prints.
- <del>User adjustable dock icon.
- <del>Fix crop, text, badge after reworking the canvas. 
- <del>Rework settings UI
- <del>Add Right click Open With menu. 
- <del>Start on Login.
- <del>Redesign permissions UI. 
- <del>Redesign screen / mouse UI during screenshots. 
- <del>Add "Help" section with support contact info. 
- <del>Fixed cursor not always displaying correctly during capture.
- <del>Added better UI for screen capture. 
- <del>Optimized window closing/opening behavior. 
- <del>Added keyboard navigation between existing thumbnails.
- <del>Add rotate to Rectangle, Text, and Paste. 
- <del>Update Gallery Window UI to better show the date of images being displayed. 
</details>