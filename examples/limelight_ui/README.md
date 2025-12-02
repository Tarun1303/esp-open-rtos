# LimelightIT ADR Orchestrator Demo

This folder contains a static, front-end-only demo of the LimelightIT ADR Orchestrator UI with the dummy copy and behaviors described in the product brief.

## Preview locally

No build step is required. You can serve the files from this folder with any static file server and open the demo in your browser.

### Option 1 — Python
```bash
cd examples/limelight_ui
python3 -m http.server 8000
```
Then visit http://localhost:8000 in your browser.

### Option 2 — Node.js `serve`
```bash
cd examples/limelight_ui
npx serve
```

### Option 3 — VS Code Live Server
Open this folder in VS Code and run the **Live Server** extension to preview `index.html`.

## Notes
- All data is simulated; no backend is required.
- The UI is responsive and keyboard shortcuts are listed in the brief (e.g., `G O` for Overview).
