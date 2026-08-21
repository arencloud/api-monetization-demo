# ${{ values.displayName }} plans

Connectivity Link enforces these limits at the Gateway API route:

The native billing unit is **${{ values.billingUnit }}**. Prices are stored as
integer euro cents for monthly fees and micro-euros for each accepted unit.

| Tier | Requests/minute | Included units | Monthly hard quota | Monthly cents | Micro-euros/unit |
|---|---:|---:|---:|---:|---:|
| Free | ${{ values.freeRequestsPerMinute }} | ${{ values.freeIncludedUnits }} | ${{ values.freeMonthlyQuota }} | ${{ values.freeMonthlyPriceCents }} | ${{ values.freeOverageMicrosPerUnit }} |
| Pay as you go | ${{ values.paygRequestsPerMinute }} | ${{ values.paygIncludedUnits }} | ${{ values.paygMonthlyQuota }} | ${{ values.paygMonthlyPriceCents }} | ${{ values.paygOverageMicrosPerUnit }} |
| Developer | ${{ values.developerRequestsPerMinute }} | ${{ values.developerIncludedUnits }} | ${{ values.developerMonthlyQuota }} | ${{ values.developerMonthlyPriceCents }} | ${{ values.developerOverageMicrosPerUnit }} |
| Business | ${{ values.businessRequestsPerMinute }} | ${{ values.businessIncludedUnits }} | ${{ values.businessMonthlyQuota }} | ${{ values.businessMonthlyPriceCents }} | ${{ values.businessOverageMicrosPerUnit }} |
| Enterprise | Unlimited | Unlimited | Unlimited | ${{ values.enterpriseMonthlyPriceCents }} | 0 |

Change limits and prices through a reviewed pull request. `gitops/plans.yaml`
is the enforcement contract and the APIProduct plan annotation is the billing
contract; publication rejects inconsistent values.
