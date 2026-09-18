# Esty's Pastries — production rollout

## Architecture
- Customer site: `index.html`
- Admin site: `admin.html`
- Shared production data: Supabase Postgres
- Customer authentication: Supabase anonymous auth (no Google sign-in required)
- Admin authentication: Supabase email/password + `admins` allow-list
- Hosting: Vercel or equivalent static hosting

## Setup
1. Create a Supabase project.
2. In SQL Editor, run `supabase-schema-production.sql`.
3. Enable Anonymous Sign-Ins in Supabase Auth.
4. Create the admin email/password in Supabase Auth.
5. Insert the admin user id into `public.admins` (SQL shown below).
6. Copy `config.example.js` to `config.js` and enter only the Supabase project URL and publishable key. Never put a secret/service-role key in the browser.
7. Deploy the folder to Vercel/Netlify/Cloudflare Pages.
8. Test customer and admin from two separate devices at the same time.

Admin SQL after creating the Auth user:
`insert into public.admins(user_id) values ('AUTH_USER_UUID');`

## Important
- The included payment details are Opay / Chisom Jennifer Onuoha / 8131238561.
- Transfer is still manually confirmed by admin; this is intentional unless a payment API is later integrated.
- Stock is changed transactionally in the database, not browser localStorage.
- Do not expose the Supabase secret/service-role key in frontend code.
- True WhatsApp/SMS/push stock notifications require a notification provider and customer opt-in; this package leaves that integration as the final external service step.

## Browser test matrix
Current iOS Safari; Android Chrome/Firefox; macOS Safari/Chrome/Firefox; Windows Chrome/Edge/Firefox; Linux Chrome/Firefox. Test two devices concurrently for stock, payment confirmation, and supply status.
