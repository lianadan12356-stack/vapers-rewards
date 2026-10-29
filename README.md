# VAPERS Rewards app starter

A phone-first loyalty app starter for a cash-only store, with a Hooleesheet maker signature. Customers open a unique link and see their own card status. The owner signs in, creates cards, scans the customer QR, adds stamps and redeems completed rewards.

## What is included

- `index.html` — customer read-only card, owner sign-in, card creation/share, QR display and scan, stamp/redeem actions, and a downloadable personalized PNG card with its unique QR.
- `schema.sql` — Supabase/Postgres tables, public status lookup and owner-only functions.
- `config.js.example` — browser-safe project settings template.
- `preview.html`, `card-front.svg`, `card-back.svg` — responsive card design preview and print artwork.

## Before live use

This starter requires a Supabase project and HTTPS hosting. Camera access in browsers requires a secure origin (HTTPS or localhost). Do not use real customer data until setup is complete and you have confirmed the owner access flow.

1. Create a Supabase project.
2. In Supabase SQL Editor, run `schema.sql`.
3. Create the owner's account in Supabase Authentication. Disable public sign-up after the owner account is ready.
4. In Authentication → Users, copy the owner's user UUID. In SQL Editor, register that one account:

   ```sql
   insert into public.store_owners (user_id)
   values ('PASTE-OWNER-USER-UUID-HERE');
   ```

5. If desired, change store name/reward label in SQL Editor:

   ```sql
   update public.store_settings
   set store_name = 'VAPERS', reward_label = 'Your chosen free reward'
   where singleton = true;
   ```

6. Fill in `config.js` with the project's URL and publishable key from Supabase Project Settings → API Keys. The publishable key is designed for browser use; never put a secret or service-role key in the browser.
7. Upload `index.html` and `config.js` to an HTTPS static host.
8. Open the site on the owner's phone, sign in, create a test card, open it on another device, and test a stamp and reward redemption before issuing customer cards.

## Default behavior

- One stamp per owner-confirmed qualifying purchase.
- At 10 stamps, the owner redeems one reward; the customer's progress then resets to 0/10. The event log keeps the redemption record.
- More stamps cannot be added while a reward is waiting to be redeemed.
- Owners can search customers, edit display names, and delete/deactivate cards. Deleting a card clears the customer name from the active list and disables its QR while retaining stamp and redemption history.
- A card QR is a bearer link. Anyone who has that link can view that card's status, but cannot edit it. Treat the link as private and deactivate/reissue a card if it is shared or lost.
- Customer records store only an optional display name, member code, card token and event history. Avoid collecting phone numbers unless needed to send the link.

## Libraries loaded by the page

The page loads Supabase JS, QRCode.js and html5-qrcode from public CDNs. Scanning requires camera permission. For a production deployment, pin and self-host approved library files if you want the app to keep working independently of those CDNs.
