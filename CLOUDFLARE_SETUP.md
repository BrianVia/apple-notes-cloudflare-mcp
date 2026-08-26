# Cloudflare setup

Account: `Brian Via` (`d1d5680013391ca21665add23eee6426`).

| Environment | Worker | KV binding | Namespace ID |
| --- | --- | --- | --- |
| Default | `notekeeper` | `NOTES` | `f329bf44dae745c7a31d2ed5996ed179` |
| Production | `notekeeper-prod` | `NOTES` | `69db83dc707e4c7e95478a437a746631` |

The only secret is `API_TOKEN`; set it separately in each deployed environment:

```sh
cd apps/api
npx wrangler secret put API_TOKEN
npx wrangler secret put API_TOKEN --env production
```
