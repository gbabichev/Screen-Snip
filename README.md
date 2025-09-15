<div align="center">

# Screen Snip

<picture>
  <source srcset="Documentation/icon-dark.png" media="(prefers-color-scheme: dark)">
  <source srcset="Documentation/icon-light.png" media="(prefers-color-scheme: light)">
  <img src="Documentation/icon-light.png" alt="App Icon" width="100">
</picture>
<br/><br/>

A small yet powerful **macOS app** for taking & editing screenshots!

Inspired by Greenshot on Windows - the goal is to make a tiny app that can do the basics and look great while doing it. 

</div>

## 🖥️ Screenshots 

<p align="center">
    <a href="Documentation/App2.png"><img src="Documentation/App2.png" width="45%"></a>
</p>

## 🖥️ Features, Tools, and Settings

### Features
- Take screenshots!
  - With a global hotkey even when the app is in the background. 
- Open Images for editing. 
  - Native "Open With" integration in Finder. 
- Copy to Clipboard / Save / Save As. 


### Tools
| Tool       | Shortcut   | Notes              |
|:---------------|:--------:|-------------------:|
| Take Screenshot              | ⌘ + ⇧ + 2     | Command + Shift + 2       |
| Pointer Tool                 | ⌘ + 1         | Moves objects around      |
| Pen Tool                     | ⌘ + 2         | Draw lines. |
| Arrow Tool                   | ⌘ + 3         | Draw lines with arrows.|
| Highlighter                  | ⌘ + 4         | Highlights. |
| Rectangle Tool               | ⌘ + 5         | Draw squres / rectangles |
| Oval Tool                    | ⌘ + 6         | Draw circles / ovals |
| Badge Tool                   | ⌘ + 7         | Incremental Numbers |
| Text Tool                    | ⌘ + 8         | Insert text. Colored backgrounds optional.  |
| Crop Tool                    | ⌘ + 9         | Crops. |
| Reset Zoom                   | ⌘ + 0         |  |
| Zoom In                      | ⌘ + +         |  |
| Zoom Out                     | ⌘ + -         |  |


### ⚙️ Settings

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





## 🔍 Troubleshooting



## 🖥️ Install & Minimum Requirements

- macOS 26.0 or later  
- Apple Silicon & Intel (Not tested on Intel)
- ~20 MB free disk space  


### ⚙️ Installation

(when released) Download from Releases. It's signed & notarized!

### ⚙️ Build it yourself!

Clone the repo and build with Xcode:

<!-- ```bash
git clone https://github.com/gbabichev/thumbnailer.git
cd thumbnailer
open thumbnailer.xcodeproj
``` -->

## Known Issues
- Zooming doesn't track your cursor. 

## 📝 Changelog

### 1.0 
- Not released yet. Build yourself to follow along!

## 📄 License

MIT — free for personal and commercial use. 

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
</details>