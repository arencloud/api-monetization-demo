# ${{ values.displayName }} plans

The native billing unit is **${{ values.billingUnit }}**.

| Tier | Requests/minute | Included units | Monthly hard quota | Monthly cents | Micro-euros/unit |
|---|---:|---:|---:|---:|---:|
| Free | ${{ values.freeRequestsPerMinute }} | ${{ values.freeIncludedUnits }} | ${{ values.freeMonthlyQuota }} | ${{ values.freeMonthlyPriceCents }} | ${{ values.freeOverageMicrosPerUnit }} |
| Pay as you go | ${{ values.paygRequestsPerMinute }} | ${{ values.paygIncludedUnits }} | ${{ values.paygMonthlyQuota }} | ${{ values.paygMonthlyPriceCents }} | ${{ values.paygOverageMicrosPerUnit }} |
| Developer | ${{ values.developerRequestsPerMinute }} | ${{ values.developerIncludedUnits }} | ${{ values.developerMonthlyQuota }} | ${{ values.developerMonthlyPriceCents }} | ${{ values.developerOverageMicrosPerUnit }} |
| Business | ${{ values.businessRequestsPerMinute }} | ${{ values.businessIncludedUnits }} | ${{ values.businessMonthlyQuota }} | ${{ values.businessMonthlyPriceCents }} | ${{ values.businessOverageMicrosPerUnit }} |
| Enterprise | Unlimited | Unlimited | Unlimited | ${{ values.enterpriseMonthlyPriceCents }} | 0 |

Connectivity Link enforces these limits before Camel performs mapping or calls
downstream systems, protecting both integration compute and partner capacity.
Publication checks that these limits match the product-scoped billing terms.
