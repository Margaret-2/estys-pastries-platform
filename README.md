# Esty's Pastries — Production V5

This package is the production foundation for Esty's Pastries. It uses Supabase Auth + Postgres, database transactions for stock, RLS, separate payment/supply statuses, business-hour enforcement, and admin cancellation with stock restoration.

It is **not deployed to a public domain from this package alone** because deployment requires the owner's Supabase/hosting accounts. Follow `SETUP_FROM_ZERO.md`.

Never place a Supabase secret/service-role key in `config.js`. Only the project URL and publishable key belong in browser code when RLS is correctly configured.
