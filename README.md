# Nahaj Royal Treat — Web Storefront + NRT Smart POS

A single-page storefront (product catalogue, cart, checkout, WhatsApp order confirmation,
customer order lookup) and staff dashboard (Dashboard, Products, Inventory, Sales, Orders,
Customers, Expenses, Profit, Reports, AI Insights, Admin Settings) that **share one real
database** in Supabase — an order placed on the website appears in the POS instantly and
inventory updates automatically.

It's a single static `index.html` file (plus a manifest/service worker for installing it
like an app) — no build step, no server to run.

---

## 1. Set up the database (Supabase)

1. Open your project's **SQL Editor**: https://supabase.com/dashboard/project/psvvecfbfvwfdddbbcpg/sql/new
2. Paste in the entire contents of [`supabase/schema.sql`](supabase/schema.sql) and click **Run**.
   This creates the `products`, `orders`, `customers`, `expenses`, `settings` tables, the
   security rules (Row Level Security), the checkout functions, and a starter product catalogue.
3. Create your staff/admin login: **Authentication → Users → Add user**, enter your email
   and a password. That's what you'll use to sign into NRT Smart POS on the live site
   (there's no more PIN — this is a real login now).

The project URL and public ("anon") API key are already wired into `index.html`. The anon
key is *meant* to be public/embeddable in client-side code — it can only do what the RLS
policies in `schema.sql` allow (browse products, place an order). Nothing sensitive is
exposed by it.

## 2. (Optional) Turn on card payments

1. Get your **public** key from your Flutterwave dashboard → Settings → API Keys
   (starts with `FLWPUBK_TEST-…` for test mode or `FLWPUBK-…` for live).
2. Deploy the site (see below), sign into NRT Smart POS with your admin login, go to
   **Admin Settings → Payment Details**, paste the key in, and save.
3. Also fill in your bank name/account number there if you want to offer Bank Transfer.

⚠️ **Before accepting real money:** the current flow confirms a card payment using
Flutterwave's client-side callback, which is fine for testing but can in theory be spoofed
by someone editing the page. For real transactions, add a small server-side check (a
Supabase Edge Function is enough) that calls Flutterwave's "Verify Transaction" API with
your **secret** key before trusting `payment_status = 'Paid'`. Never put your secret key in
this file or anywhere client-side.

## 3. Push this code to GitHub

If you're reading this from the files Claude gave you rather than already in the repo:

```bash
cd Nahaj-Royal-Treat        # wherever you unzipped/cloned this
git init                    # only if it isn't already a git repo
git remote add origin https://github.com/dinvictaedu23-rgb/Nahaj-Royal-Treat.git
git add .
git commit -m "Nahaj Royal Treat: storefront + NRT Smart POS on Supabase"
git branch -M main
git push -u origin main
```

## 4. Deploy it live (pick one — both are free)

**Option A — GitHub Pages (simplest, same repo):**
1. On GitHub: repo → **Settings → Pages**
2. Source: **Deploy from a branch** → Branch: `main`, folder: `/ (root)` → **Save**
3. Your site goes live in a minute or two at `https://dinvictaedu23-rgb.github.io/Nahaj-Royal-Treat/`

**Option B — Vercel or Netlify (custom domain, instant redeploys on push):**
1. Sign in with GitHub, "Import Project", pick this repo.
2. Framework preset: **Other / static site**. Build command: none. Output directory: `/`.
3. Deploy — you'll get a URL immediately, and can attach your own domain (e.g.
   `nahajroyaltreat.com`) under the project's Domain settings.

Either way, once it's live, share the URL as your website. WhatsApp ordering, Flutterwave,
and the POS all work the same regardless of which host you pick.

## 5. Use it like an app

Once deployed, open the site on a phone and use the browser's **"Add to Home Screen"**
(Safari) or **"Install app"** (Chrome/Android) option — it installs like a native app with
its own icon, thanks to `manifest.json` and `sw.js`. There's nothing extra to publish to
an app store; this *is* the app.

## 6. Local development

No build tools needed. Either:
- Just double-click `index.html` and open it in a browser, **or**
- Serve it properly (recommended, since some browsers restrict `file://` pages):
  `python3 -m http.server 8000` from this folder, then visit `http://localhost:8000`.

---

## How the data flows

- **Storefront checkout** calls the `place_order()` database function, which atomically
  creates the order, reduces stock, and updates the customer record — all in one step, so
  the storefront and POS are always looking at the same numbers.
- **POS walk-in sales** use `place_pos_sale()`, the staff-only equivalent.
- **"My Orders"** on the storefront calls `get_orders_by_phone()` so a customer can see
  their own history without being able to browse anyone else's.
- Everything under **NRT Smart POS** (orders list, customers, expenses, settings changes,
  product edits) requires being signed in — enforced by Supabase Row Level Security, not
  just by hiding the buttons in the UI.

## Known limitations / good next steps

- Product photos are stored as compressed base64 images directly on the product row. This
  is simple and needs zero extra setup, but for a large catalogue with many photos,
  switching to a **Supabase Storage bucket** would be more efficient.
- Card payment confirmation should be verified server-side before going fully live (see §2).
- There's currently one shared staff/admin role — anyone who can sign in can do everything
  in the POS. If you want separate cashier vs. owner permissions later, that's a
  straightforward extension of the RLS policies plus a `role` column on a staff table.
