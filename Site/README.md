# Molehill Data Services - website

Two static pages, no build step, no dependencies:

| File | What it is |
|---|---|
| `index.html` | The consultancy site: services, how the work runs, about, contact |
| `molehill-watch.html` | The page to send prospects: what Molehill Watch is, what you get, pricing, onboarding, FAQ |
| `assets/molehill.css` | Everything visual, following `molehill_styleguide_V1.pdf` |
| `assets/molehill-logo.png` | Logo for light backgrounds |
| `assets/molehill-logo-dark.png` | Logo for dark backgrounds (white wordmark) |
| `assets/favicon.png` | The mole, for the browser tab |

## Putting it online

Anything that serves static files will do. The cheapest options, in order of effort:

- **Netlify / Cloudflare Pages** - drag this `Site` folder onto their deploy page, point `molehilldataservices.com` at it, done.
- **GitHub Pages** - push this folder to a repo, turn Pages on, set the custom domain.
- **Existing hosting** - upload the folder by FTP. Nothing here needs PHP, Node or a database.

The prospect link is then `molehilldataservices.com/molehill-watch.html` (or set up a redirect from
`/molehill-watch` to keep it tidy).

## Editing

- Prices live in one place: the tables under `<section id="pricing">` in `molehill-watch.html`.
  Delete that whole section if you would rather quote privately - the nav link and the hero's
  "See the pricing" button are the only two places that point at it.
- Contact details appear in the contact section and the footer of both pages.
- Colours and type are the three brand colours and the Krungthep/Bahnschrift stack, set once at the
  top of `molehill.css` as custom properties.
- The headings ask for Krungthep first. It ships with macOS; on Windows the pages fall back to
  Bahnschrift, which is what the invoices do too.
