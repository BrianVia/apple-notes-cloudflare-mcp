import * as Y from "yjs";
import type { Env } from "../lib/env";
import { deriveTitle } from "../lib/derive-title";

/**
 * NoteDO — one Durable Object per note.
 *
 * Responsibilities:
 *  1. Hold the authoritative Y.Doc for a note.
 *  2. Handle Yjs sync over WebSocket for real-time collaboration.
 *  3. Persist the Y.Doc binary state to DO storage on every change (cheap,
 *     local SQLite write).
 *  4. On a debounced alarm, flush the markdown text + updated_at into D1
 *     so that listing/search queries stay fast and consistent.
 *
 * The Y.Doc has a single Y.Text called "body" containing markdown. Future
 * work: add a Y.Map called "meta" if we want title/tags to also be CRDT-
 * synced (today they're managed via REST and authoritative in D1).
 *
 * We implement Yjs sync manually instead of using y-durableobjects because
 * we need tight control over the D1 flush path and auth. The wire protocol
 * is a lean subset of y-protocols/sync:
 *   - Client sends: [messageType:u8, ...payload]
 *     - 0 = SYNC_STEP_1  (client state vector)
 *     - 1 = SYNC_STEP_2  (server diff)
 *     - 2 = UPDATE       (client update)
 *   - Server sends back matching messages.
 *
 * For true production use, swap in `y-protocols` from the Yjs ecosystem —
 * this hand-rolled version is deliberate and minimal to keep the bundle
 * small and the semantics auditable.
 */

const SYNC_STEP_1 = 0;
const SYNC_STEP_2 = 1;
const UPDATE = 2;

const FLUSH_IDLE_MS = 2_000;   // flush this long after last edit
const FLUSH_MAX_MS = 10_000;   // or at least every this often if dirty

interface Session {
  ws: WebSocket;
  user_id: string;
}

export class NoteDO implements DurableObject {
  private state: DurableObjectState;
  private env: Env;
  private doc: Y.Doc;
  private sessions = new Set<Session>();
  private loaded = false;
  private dirty = false;
  /// When true, the next Y.Doc update event won't mark the DO dirty or
  /// schedule a flush. Used for initial-seed writes where the D1 row is
  /// already authoritative — prevents the flush alarm from overwriting
  /// created_at/updated_at we just persisted.
  private suppressDirty = false;
  private lastFlushAt = 0;
  private noteId: string | null = null;
  private userId: string | null = null;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.doc = new Y.Doc();

    // Persist state changes locally. This is cheap (DO-local SQLite) and
    // survives evictions.
    this.doc.on("update", (update: Uint8Array, _origin: unknown) => {
      // Always persist yjs_state so the DO survives evictions with the
      // current text. Only mark dirty / schedule a D1 flush for edits that
      // came from a real caller — silent seeds set suppressDirty=true.
      this.state.storage.put("yjs_state", Y.encodeStateAsUpdate(this.doc));
      if (this.suppressDirty) return;
      this.dirty = true;
      this.scheduleFlush();
    });
  }

  /** Lazy-load Y.Doc from DO storage on first access. */
  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return;
    const [saved, meta] = await Promise.all([
      this.state.storage.get<Uint8Array>("yjs_state"),
      this.state.storage.get<{ note_id: string; user_id: string }>("meta"),
    ]);
    if (saved) {
      Y.applyUpdate(this.doc, saved);
    }
    if (meta) {
      this.noteId = meta.note_id;
      this.userId = meta.user_id;
    }
    this.loaded = true;
  }

  /**
   * One-time binding of this DO instance to a (note_id, user_id). Called
   * by the Worker when the note is first created. Idempotent: re-binding
   * to the same pair is a no-op; re-binding to a different pair throws.
   */
  async bind(noteId: string, userId: string): Promise<void> {
    await this.ensureLoaded();
    if (this.noteId && (this.noteId !== noteId || this.userId !== userId)) {
      throw new Error("NoteDO already bound to a different note");
    }
    this.noteId = noteId;
    this.userId = userId;
    await this.state.storage.put("meta", { note_id: noteId, user_id: userId });
  }

  /** Read the current markdown body. */
  async getBody(): Promise<string> {
    await this.ensureLoaded();
    return this.doc.getText("body").toString();
  }

  /** Replace the entire body (REST PUT /notes/:id). Pass `silent: true`
   *  when the caller has already written the body to D1 and only wants the
   *  DO's Y.Doc primed for future WS clients — that path skips the flush
   *  alarm so it can't overwrite preserved created_at/updated_at. */
  async setBody(body: string, { silent = false }: { silent?: boolean } = {}): Promise<void> {
    await this.ensureLoaded();
    const ytext = this.doc.getText("body");
    const prev = this.suppressDirty;
    this.suppressDirty = silent;
    try {
      this.doc.transact(() => {
        ytext.delete(0, ytext.length);
        ytext.insert(0, body);
      }, "rest");
    } finally {
      this.suppressDirty = prev;
    }
  }

  /** Schedule the next D1 flush via DO alarm. */
  private async scheduleFlush(): Promise<void> {
    const now = Date.now();
    const existing = await this.state.storage.getAlarm();
    const idleTarget = now + FLUSH_IDLE_MS;
    // Respect an existing earlier alarm; respect MAX cap.
    const maxTarget = this.lastFlushAt
      ? this.lastFlushAt + FLUSH_MAX_MS
      : idleTarget;
    const target = Math.min(idleTarget, maxTarget);
    if (!existing || existing > target) {
      await this.state.storage.setAlarm(target);
    }
  }

  async alarm(): Promise<void> {
    await this.flushToD1();
  }

  private async flushToD1(): Promise<void> {
    if (!this.dirty || !this.noteId || !this.userId) return;
    const body = this.doc.getText("body").toString();
    const title = deriveTitle(body);
    const now = new Date().toISOString();

    try {
      // Only touch updated_at when the body (or title) actually changed. A
      // DO that's `dirty=true` but whose Y.Doc already matches D1 — e.g.
      // after a silent seed followed by eviction cycles — must not bump
      // timestamps on every alarm fire. The `body != ?` predicate makes the
      // flush idempotent under that race.
      await this.env.DB.prepare(
        `UPDATE notes SET title = ?, body = ?, updated_at = ?
         WHERE id = ? AND user_id = ? AND (body != ? OR title != ?)`,
      )
        .bind(title, body, now, this.noteId, this.userId, body, title)
        .run();

      // Keep FTS in sync. FTS5 external-content requires manual updates.
      await this.env.DB.prepare(
        `INSERT INTO notes_fts(rowid, title, body, tags) VALUES (
           (SELECT rowid FROM notes WHERE id = ?),
           ?,
           ?,
           (SELECT COALESCE(GROUP_CONCAT(t.name, ' '), '')
              FROM note_tags nt JOIN tags t ON t.id = nt.tag_id
              WHERE nt.note_id = ?)
         ) ON CONFLICT(rowid) DO UPDATE SET title = excluded.title, body = excluded.body, tags = excluded.tags`,
      )
        .bind(this.noteId, title, body, this.noteId)
        .run();

      this.dirty = false;
      this.lastFlushAt = Date.now();
    } catch (err) {
      console.error("NoteDO flush failed:", err);
      // Retry on the next alarm cycle.
      await this.state.storage.setAlarm(Date.now() + FLUSH_IDLE_MS);
    }
  }

  /** Entry point — Worker calls this via stub.fetch(). */
  async fetch(request: Request): Promise<Response> {
    await this.ensureLoaded();
    const url = new URL(request.url);

    if (url.pathname === "/ws") {
      return this.handleWebSocket(request);
    }

    if (url.pathname === "/body" && request.method === "GET") {
      return new Response(await this.getBody(), {
        headers: { "content-type": "text/markdown; charset=utf-8" },
      });
    }

    if (url.pathname === "/body" && request.method === "PUT") {
      const body = await request.text();
      const silent = url.searchParams.get("silent") === "1";
      await this.setBody(body, { silent });
      return new Response(null, { status: 204 });
    }

    if (url.pathname === "/bind" && request.method === "POST") {
      const { note_id, user_id } = (await request.json()) as {
        note_id: string;
        user_id: string;
      };
      await this.bind(note_id, user_id);
      return new Response(null, { status: 204 });
    }

    if (url.pathname === "/flush" && request.method === "POST") {
      await this.flushToD1();
      return new Response(null, { status: 204 });
    }

    return new Response("not found", { status: 404 });
  }

  private handleWebSocket(request: Request): Response {
    const upgrade = request.headers.get("Upgrade");
    if (upgrade !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    // Auth happened in the Worker before proxying here; we trust the
    // X-User-Id header the Worker attached.
    const user_id = request.headers.get("X-User-Id");
    if (!user_id || user_id !== this.userId) {
      return new Response("forbidden", { status: 403 });
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.state.acceptWebSocket(server);

    const session: Session = { ws: server, user_id };
    this.sessions.add(session);

    // Send initial sync step 1 (empty state vector → client responds with
    // its own, we diff).
    this.sendSyncStep1(server);

    return new Response(null, { status: 101, webSocket: client });
  }

  // Hibernation-compatible handlers. Workers runtime calls these when a
  // message arrives on a hibernated WebSocket.
  async webSocketMessage(ws: WebSocket, raw: ArrayBuffer | string): Promise<void> {
    if (typeof raw === "string") return; // we only speak binary
    const msg = new Uint8Array(raw);
    if (msg.length === 0) return;
    const type = msg[0];
    const payload = msg.subarray(1);

    if (type === SYNC_STEP_1) {
      // Client sent its state vector. Reply with the diff it needs.
      const diff = Y.encodeStateAsUpdate(this.doc, payload);
      this.send(ws, SYNC_STEP_2, diff);
    } else if (type === SYNC_STEP_2 || type === UPDATE) {
      // Apply the update locally and broadcast to other clients.
      Y.applyUpdate(this.doc, payload, "ws");
      this.broadcast(UPDATE, payload, ws);
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    for (const s of this.sessions) {
      if (s.ws === ws) {
        this.sessions.delete(s);
        break;
      }
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.webSocketClose(ws);
  }

  private sendSyncStep1(ws: WebSocket) {
    const sv = Y.encodeStateVector(this.doc);
    this.send(ws, SYNC_STEP_1, sv);
  }

  private send(ws: WebSocket, type: number, payload: Uint8Array) {
    const buf = new Uint8Array(payload.length + 1);
    buf[0] = type;
    buf.set(payload, 1);
    try {
      ws.send(buf);
    } catch {
      // will be cleaned up on next close event
    }
  }

  private broadcast(type: number, payload: Uint8Array, except: WebSocket) {
    for (const s of this.sessions) {
      if (s.ws !== except) this.send(s.ws, type, payload);
    }
  }
}

