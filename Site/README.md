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

## The contact forms

Both pages carry a form: a full one on the home page, a shorter one on the Molehill Watch page
asking how many instances they run. Neither needs a server of your own - pick one of these:

**Netlify (nothing to configure).** Deploy this folder to Netlify and the forms work as they are.
Netlify spots `data-netlify="true"`, catches the POST, and submissions appear under
*Site settings > Forms*, with e-mail notifications you turn on there. The free tier covers 100 a
month. The two forms are named `contact` and `molehill-watch`, so you can tell them apart.

**Anywhere else (one attribute).** Sign up for a form service - [Formspree](https://formspree.io) and
[Web3Forms](https://web3forms.com) both have free tiers - and put the endpoint they give you on both
forms:

```html
<form class="form" data-contact name="contact" method="POST" data-endpoint="https://formspree.io/f/xxxxxxx" ...>
```

`assets/contact.js` sends it in the background, so the visitor stays on the page and sees
"Thank you - that has arrived". If the send fails for any reason, it shows your e-mail address
instead of losing the enquiry. Without JavaScript the form posts normally and the service shows its
own thank-you page.

**Spam.** Each form has a hidden field a person never sees; anything that fills it in is dropped
before it is sent, and Netlify uses the same field for its own filtering. If the bots ever get
past that, both services offer a captcha you can turn on.

**What arrives.** Name, company, e-mail, phone, how many instances, what would help most, the
message - plus which page it came from, so you know whether they were reading about Molehill Watch.

## Company details in the footer

Both footers carry the line a limited company owes anyone reading its website: registered name,
where it is registered and the number. The registered office is deliberately not there yet - the
company is registered at a private address. Strictly, the disclosure rules expect the registered
office on the site too, so the tidy fix is a service address (an accountant's, or a registered
office service) at Companies House, and then adding it to the same line. There is a comment in both
footers showing where it goes.

## Editing

- Prices live in one place: the tables under `<section id="pricing">` in `molehill-watch.html`.
  Delete that whole section if you would rather quote privately - the nav link and the hero's
  "See the pricing" button are the only two places that point at it.
- Contact details appear in the contact section and the footer of both pages.
- Colours and type are the three brand colours and the Krungthep/Bahnschrift stack, set once at the
  top of `molehill.css` as custom properties.
- The headings ask for Krungthep first. It ships with macOS; on Windows the pages fall back to
  Bahnschrift, which is what the invoices do too.
