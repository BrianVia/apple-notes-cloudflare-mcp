# launchd setup
1. Run `npx wrangler secret put API_TOKEN --env production` from `apps/api`.
2. Copy the plist to `~/Library/LaunchAgents/com.brianvia.notes-push.plist`.
3. Replace `__NOTEKEEPER_DIR__`, `__HOME__`, and `__NK_API_TOKEN__` in that copy.
4. Load it: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.brianvia.notes-push.plist`.
5. Tail logs: `tail -f ~/Library/Logs/notes-push.log`.
