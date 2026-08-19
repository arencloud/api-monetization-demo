# ${{ values.displayName }} plans

| Tier | Requests/minute | Monthly hard quota | Commercial price |
|---|---:|---:|---|
| Free | ${{ values.freeRequestsPerMinute }} | ${{ values.freeMonthlyQuota }} | Governed by the central Billing catalog |
| Developer | ${{ values.developerRequestsPerMinute }} | ${{ values.developerMonthlyQuota }} | Governed by the central Billing catalog |
| Enterprise | Unlimited | Contract | Contract |

Connectivity Link enforces these limits before Camel performs mapping or calls
downstream systems, protecting both integration compute and partner capacity.

