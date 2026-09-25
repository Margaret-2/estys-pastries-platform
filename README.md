# Esty's Pastries — Production V8

V8 is an incremental update of the Production V5 website. The existing customer/admin experience, Supabase connection, design, products and payment settings are preserved while the site is updated for the V8 weekly-ordering backend.

## V8 updates
- Weekly periods: admin explicitly starts the current Monday–Friday week.
- Customer ordering window: Monday–Friday, 7:30 AM–5:00 PM Lagos time, only while the current week is open.
- Credit purchase option with later Payment Received confirmation.
- Customer order history and cancellation before supply.
- Pending refund → Refunded workflow.
- Current-week dashboard metrics with carry-over credit/refund obligations.
- Weekly/monthly/quarterly/all-time order views.
- Order sorting and pagination.
- Customer order-count and paid-spend period views.
- Sequential EP order numbers for new orders via the V8 Supabase sequence.

## Deployment
1. Keep `config.js` connected to the same Supabase project.
2. Deploy these website files only after the V8 Supabase migration has already been applied.
3. Do not delete or recreate the Supabase project.
