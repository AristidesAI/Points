# Points Documentation

Built with [Just the Docs](https://just-the-docs.com/), a documentation theme for Jekyll.

## Local Development

```bash
cd docs
bundle install
bundle exec jekyll serve
```

The site will be available at `http://localhost:4000`.

## Structure

```
docs/
├── _config.yml          # Jekyll + Just the Docs configuration
├── _sass/custom/        # Custom SCSS (dark theme)
├── assets/              # Point cloud background script
├── index.md             # Home page
├── getting-started.md   # Quick start guide
├── integrations.md      # MIDI, OSC, NDI, audio setup
└── nodes/               # Node reference (one page per family)
    ├── index.md         # Reference overview
    ├── source.md        # Depth, Video Color, etc.
    ├── grid.md          # Pinout, Domain, etc.
    ├── filter.md        # EMA, Fill Holes, etc.
    ├── shape.md         # Size, Shape, Spin, etc.
    ├── move.md          # Depth Drive, Ripple, etc.
    ├── color.md         # Palette, Duotone, etc.
    ├── signal.md        # Math, Noise, Triggers
    ├── body.md          # Hand, Face, Gestures
    ├── time-stage.md    # LFO, Camera, Light
    └── output-tools.md  # NDI, Record
```
