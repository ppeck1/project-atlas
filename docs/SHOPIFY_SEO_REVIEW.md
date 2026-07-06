# Shopify SEO Review

Project Atlas includes a draft-backed Shopify SEO review workflow for storefront product catalogs such as `sinternetcult.com`.

The workflow is intentionally local and stage-only. It can import Shopify-like product JSON, analyze SEO readiness, prioritize product issues, export review packets, and queue product-level SEO improvement tasks. It does not write to Shopify. The snapshot schema is ready for a future read-only Shopify Admin API catalog sync path, but this slice does not require Admin API credentials.

Imported products are not selected by default. Operators must explicitly select products manually or through review filters such as critical issues, missing meta data, missing alt text, or low score.

## Boundary

- No live Shopify writes.
- No write scopes, product mutation, order access, or customer access.
- No secrets in metadata, drafts, DB rows, logs, docs, or committed files.
- No broad MCP Shopify tools.
- No ranking guarantees.
- No meta-keyword generation, keyword stuffing, or unsupported product claims.
- Product updates are queued as staged proposals only.

## Import Shape

The importer accepts both v1 and v2 review snapshots.

Minimal v1 shape:

```json
{
  "shopDomain": "sinternetcult.com",
  "products": [
    {
      "id": "gid://shopify/Product/1",
      "handle": "chaos-tee",
      "title": "Chaos Tee",
      "product_type": "Apparel",
      "vendor": "Sinternet Cult",
      "tags": "tee, internet",
      "seo": {
        "title": "Chaos Tee | Sinternet Cult",
        "description": "A readable product-specific snippet."
      },
      "body_html": "<p>Product description.</p>"
    }
  ]
}
```

V2 can also include:

- `brandName`, otherwise Atlas falls back to the most common product vendor, then shop domain, then `Sinternet Cult`
- `images` with `id`, `src`, `alt`, `width`, `height`, and `position`
- `variants` with `id`, `title`, `sku`, `price`, `barcode`, options, and availability
- `collections`, `collectionTitles`, or `collection_handles`
- `onlineStoreUrl`, `canonicalUrl`, `publishedAt`, and `updatedAt`

The decoder accepts Shopify REST-style keys and common GraphQL-style `edges/node` or `nodes` shapes where practical.

## Analysis

Each product receives a deterministic `shopify_seo_analysis_v1` packet:

- Score from 0 to 100 for prioritization only
- Breakdown for search snippet, product content, image alt text, URL/taxonomy, and merchant readiness
- Structured issues with severity, category, field, evidence, and suggested action
- Strength notes

The score is an editorial triage signal. It is not a Google ranking score.

Issue categories include:

- `snippet`
- `content`
- `image`
- `url`
- `taxonomy`
- `merchant`
- `governance`

## Proposal Seeds

Atlas creates deterministic `shopify_seo_proposal_seed_v1` suggestions before any LLM work:

- SEO title
- Meta description
- Product description outline
- Image alt text proposals
- Tags
- Risk warnings

Proposal seeds use imported product data only. They avoid material, shipping, origin, authenticity, medical, official affiliation, and exclusivity claims unless the imported product data supports them.

## Queue Model

The first supported approval unit is one product per batch. Queue context includes:

- Product JSON
- SEO analysis
- Proposal seed
- Required output schema
- Allowed fields
- Forbidden fields
- `writePolicy: stage_only_until_user_approved`

Allowed fields:

- `seo.title`
- `seo.description`
- `body_html`
- `tags`
- `images.alt`

Forbidden fields include price, inventory, variants, vendor, product type, status, and published scope.

## Exports

The Project Detail Shopify SEO section can export:

- JSON review packet with snapshot, analysis, and proposal seeds
- CSV review table
- Markdown review packet

The CSV review table includes product id, handle, title, status, score, issue counts, current/proposed SEO fields, missing alt count, thin-description flag, and queued state.

## Read-only Admin API Sync

Read-only Shopify Admin API sync should feed the same `ShopifySeoReviewSnapshot` v2 model and preserve this draft-backed review surface. The future client should keep the access token in memory only, send it as `X-Shopify-Access-Token`, refresh before expiration, and reject GraphQL mutation strings locally before a request can be sent.

Local credentials may come from environment variables or `.local/shopify_sinternetcult.env`:

```text
SHOPIFY_SHOP=sinternetcult.myshopify.com
SHOPIFY_CLIENT_ID=...
SHOPIFY_CLIENT_SECRET=...
SHOPIFY_API_VERSION=2026-01
SHOPIFY_SYNC_MODE=read_only
```

The `.local/` directory and common Shopify secret/token filenames are ignored by git. Do not paste real values into Project Atlas metadata, drafts, docs, queue context, logs, or committed files.

### Read-only Shopify Connection Walkthrough

1. In Shopify admin, create a custom app for the store.
2. Grant only read scopes needed for catalog review, starting with product/catalog read access such as `read_products`.
3. Store the client id, client secret, shop, API version, and `SHOPIFY_SYNC_MODE=read_only` in environment variables or `.local/shopify_sinternetcult.env`.
4. Import the generated snapshot JSON into Project Detail -> Shopify SEO.
5. Review, export, and queue product batches from the snapshot.

For `sinternetcult.com`, the public repo should only contain the shop domain and non-secret workflow docs. Shopify credentials belong in local ignored secret files or process environment only.

## Future MCP Path

Future MCP tools should stay read-first and narrow:

- `atlas.shopify_seo_snapshot`
- `atlas.shopify_seo_product_context`
- `atlas.shopify_seo_issue_summary`
- `atlas.queue_shopify_seo_review_batch`

No live Shopify mutation should be exposed through MCP until the review, approval, and receipt model is proven stable.
