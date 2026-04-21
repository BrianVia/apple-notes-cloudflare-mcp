# Cloudflare setup

Last updated: 2026-04-21

This project has been provisioned on Cloudflare and deployed in both the default
environment and the `production` environment.

## Account

- Account name: `Brian Via`
- Account ID: `d1d5680013391ca21665add23eee6426`

## Worker deployments

- Default environment:
  - Worker name: `notekeeper`
  - URL: `https://notekeeper.brian-via.workers.dev`
  - Version ID: `147142f2-174c-422b-957f-388deffb1759`
- Production environment:
  - Worker name: `notekeeper-prod`
  - URL: `https://notekeeper-prod.brian-via.workers.dev`
  - Version ID: `e6afdc29-3786-4b76-ac32-265a90a36476`

## Bound resources

### Default environment

- D1
  - Database name: `notekeeper`
  - Database ID: `2e5788eb-3592-48b0-a4db-d251ba460d66`
- KV
  - Binding: `CACHE`
  - Namespace title: `NOTEKEEPER_CACHE`
  - Namespace ID: `f329bf44dae745c7a31d2ed5996ed179`
- R2
  - Binding: `ATTACHMENTS`
  - Bucket name: `brianvia-notekeeper-attachments`
- Durable Objects
  - Binding: `NOTE_DO`
  - Class: `NoteDO`

### Production environment

- D1
  - Database name: `notekeeper-prod`
  - Database ID: `3a4ce9e5-e131-46a6-8890-ed003906c9e0`
- KV
  - Binding: `CACHE`
  - Namespace title: `production-CACHE`
  - Namespace ID: `69db83dc707e4c7e95478a437a746631`
- R2
  - Binding: `ATTACHMENTS`
  - Bucket name: `brianvia-notekeeper-attachments-prod`
- Durable Objects
  - Binding: `NOTE_DO`
  - Class: `NoteDO`

## Secrets

These secrets were created remotely in both the default and `production`
environments:

- `JWT_SECRET`
- `ATTACHMENT_SIGNING_SECRET`

The generated values were not written into the repo. If needed, rotate them with:

```bash
cd apps/api
printf '%s' '<new-value>' | wrangler secret put JWT_SECRET --env ''
printf '%s' '<new-value>' | wrangler secret put ATTACHMENT_SIGNING_SECRET --env ''
printf '%s' '<new-value>' | wrangler secret put JWT_SECRET --env production
printf '%s' '<new-value>' | wrangler secret put ATTACHMENT_SIGNING_SECRET --env production
```

## Database state

The initial migration was applied remotely to both databases:

- `migrations/0001_init.sql`

Commands used:

```bash
cd apps/api
wrangler d1 migrations apply notekeeper --remote
wrangler d1 migrations apply notekeeper-prod --remote --env production
```

## Config state

The live Cloudflare resource IDs and bucket names are wired into
[apps/api/wrangler.toml](/home/via/Development/Personal/notekeeper/apps/api/wrangler.toml).

## Notes

- A pre-existing generic KV namespace named `CACHE` already existed in the
  account. It is not used for this app's default environment.
- The default environment was switched to a dedicated KV namespace:
  `NOTEKEEPER_CACHE`.
- `workers.dev` is currently enabled via Wrangler defaults because it is not
  explicitly disabled in config.
- Preview URLs are also currently enabled via Wrangler defaults.

## If provisioning needs to be repeated

Core commands:

```bash
cd apps/api
wrangler whoami
wrangler d1 create notekeeper
wrangler d1 create notekeeper-prod
wrangler kv namespace create NOTEKEEPER_CACHE
wrangler kv namespace create CACHE --env production
wrangler r2 bucket create brianvia-notekeeper-attachments
wrangler r2 bucket create brianvia-notekeeper-attachments-prod
wrangler deploy --env ''
wrangler deploy --env production
```
