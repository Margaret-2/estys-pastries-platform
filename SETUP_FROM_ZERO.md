# Esty's Pastries — go-live setup

## 1. Supabase
1. Create a Supabase project.
2. Authentication → Providers → enable Anonymous Sign-Ins.
3. Authentication → Users → Add user for the admin (email + strong password).
4. SQL Editor → run `supabase-schema-production.sql`.
5. Copy the admin user UUID and run:

```sql
insert into public.admins(user_id) values (''PASTE_AUTH_USER_UUID'');
```

6. Project Settings → API → copy the Project URL and **Publishable key** into `config.js`. Never use a secret/service-role key in the browser.

## 2. Hosting
Upload this folder to a GitHub repository, import it into Vercel, and deploy. Set the project root to the folder containing `index.html`.

## 3. First live tests
- Customer: open the public URL on one phone.
- Admin: open `/admin.html` on a different device.
- Place a Small and Big order.
- Confirm payment from admin.
- Mark supplied.
- Confirm stock changed for both devices.
- Attempt to order more stock than remains.
- Attempt after Friday 5:00 PM and on Saturday/Sunday.
- Cancel an unsupplied order and confirm stock returns.

## 4. Security before launch
- Enable MFA on the Supabase account.
- Keep service-role/secret keys server-side only.
- Confirm RLS is enabled on every public table.
- Do not publish `config.js` with anything other than the Supabase URL and publishable key.
- Do not share the admin password.

## 5. Customer notifications
The ordering system is production-ready without collecting phone numbers. WhatsApp/SMS/push stock notifications are intentionally a separate opt-in integration. Add a provider only after the customer consent flow is agreed.
