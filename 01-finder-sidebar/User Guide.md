# Folderis User Guide

> **How to use:**
>
> 1. Open a folder, select one or more files, then describe what you want done in the panel — that's your "instruction".
> 2. Results are saved in the current folder, or you can name a target folder in the instruction.
> 3. Chat history is bound to each file or folder — select it again and your previous instructions are right there.

# All-in-one (select a mix of file types, state one goal)
- Select a pile of images and documents: "Turn these into an HTML slide deck"
- Select a few reports and notes: "Summarize into a one-page weekly report, save as report.md"
- Select a meeting recording and whiteboard photos: "Transcribe into minutes, compress the photos, and archive together"
- Select everything in a project folder: "Sort into subfolders by type and export an inventory Excel"

# Mixed-file processing
- "Rename these to vacation_001, vacation_002…, ordered by capture time"
- "Sort into subfolders by type: images, documents, videos"
- "Delete duplicates based on MD5"

# Images

**Editing**
- "Remove the background from all of these"
- "Add a translucent watermark bottom-right: © 2026 Vanessa"
- "Rotate all 90° clockwise" / "Flip all horizontally"

**Compression & conversion**
- "Compress these PNGs, visually lossless"
- "Compress these JPGs, visually lossless" (true lossless JPG has little headroom; defaults to high-quality re-encode)
- "Convert all to PNG" / "Convert all to WebP"
- "Resize to 1920 px wide, keep aspect ratio"

**Extraction & composition**
- "OCR each screenshot into a same-named txt"
- "OCR these receipts, put the amounts and dates into Excel, then summarize by category"
- "Stitch these images vertically into one long image, in order"
- "Combine these images into one PDF, in order"

**Advanced**
- "Crop 800×600 from (100,50)"
- "Cut each of these long screenshots into 3 pieces"
- "Generate an .ico from each of these logos"

# Documents
- "Merge these Word/TXT files into one, in filename order"
- "Convert these contracts to PDF, add a CONFIDENTIAL watermark, and zip with password 8888"
- "Clean up these txt files: strip trailing spaces, collapse blank lines"
- "These files are GBK-encoded, convert all to UTF-8"

**Advanced**
- "Split this txt into files of 1000 lines each"
- Select a Word template and an Excel roster: "Generate one per person" (use {{name}}-style placeholders in the template)

## PDF

> PDF → Word keeps text only by default; to preserve layout/tables/images, the AI will ask whether to install LibreOffice (one-time, ~700 MB).

**Whole-file operations**
- "Merge these PDFs into one"
- "Compress these PDFs losslessly"
- "Remove the password and copy restrictions from these PDFs" (tell it the password)
- "Encrypt with password abc123"

**Page operations**
- "Split every page into its own file"
- "Extract pages 2–5"
- "Reorder pages to 3,1,2"

**Conversion**
- "Convert each of these PDFs to txt"
- "Convert to images/txt/Word"

**Watermark & stamp**
- "Add a CONFIDENTIAL watermark to all these PDFs"
- Select PDFs and a stamp image: "Stamp it on the bottom-right of the last page"

## Excel

**Sheets & rows**
- "Convert to CSV" / "Convert these CSVs to Excel"
- "Split each worksheet into its own file"
- "Deduplicate by column 2"
- Select two sheets: "Diff them by the id column"

**Columns**
- "Split column 1 on - into name and phone columns"
- "Merge columns 2 and 3 into one"

**Summarize & reconcile**
- "Sum expenses by department into a summary sheet"
- Select this year's and last year's sheets: "Update leads and conversions into the YoY sheet by branch" (formula columns untouched)
- "Split by the Branch column into separate files"
- Select two customer sheets: "Names don't match exactly — merge the payments in by similarity" (confidence column included)

**Extraction**
- "Pull all phone numbers out of these sheets, dedupe, tag by branch" (emails / ID numbers too)

**Advanced**
- "This CSV is huge — how many rows, and what does the header look like?"

# Video

> The first time you use audio/video features, the AI will ask whether to download the ffmpeg component (one-time, ~80 MB).

**Conversion & compression**
- "Convert all these mov files to mp4"
- "Compress all to 1080p, roughly half the size, keep it visually lossless"

**Extraction & composition**
- "Extract the audio track from each of these as mp3"
- "Grab a frame every 10 seconds and save as images"
- "Join these three clips into one, in filename order"

**Advanced**
- "Trim each of these to seconds 10–30"
- "Turn the first 5 seconds of each into a GIF, 480 wide"
- Select videos and subtitles: "Burn the subtitles in" (auto-paired by matching filenames)

# Audio
- "Convert all these wav files to m4a"
- "Join these two clips together"
- "Trim the first 5 seconds off each of these recordings"

**Advanced**
- "Denoise all of them" (vocal/instrumental separation needs demucs; the AI will guide you)
- "Transcribe this meeting recording" (offline transcription; grant speech-recognition access the first time)
- "Transcribe it and summarize into meeting minutes"

# Knowledge base
- "Convert these Word/Excel/PDF files to Markdown" (headings and tables preserved)

# Everything else
- Coding: open a project folder and just describe what you want — start a project from scratch, link it to GitHub, modify code, all of it
- Archives: unzip, split archives, repair broken zips — select and say the word
- Secure sharing: "Zip these files with password abc123"
- QR codes: "Turn this link into a QR code" / select screenshots: "Read the QR codes in these"
